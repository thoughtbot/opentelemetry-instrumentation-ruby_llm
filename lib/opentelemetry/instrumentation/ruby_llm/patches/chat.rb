# frozen_string_literal: true

require_relative "span_helpers"
require_relative "../adapters"
require_relative "../message_formatter"

module OpenTelemetry
  module Instrumentation
    module RubyLLM
      module Patches
        module Chat
          include SpanHelpers

          attr_writer :otel_conversation_id

          def otel_conversation_id
            id = @otel_attributes&.[]("gen_ai.conversation.id") || @otel_conversation_id
            id.respond_to?(:call) ? id.call : id
          end

          def with_otel_attributes(attributes)
            @otel_attributes = attributes
            self
          end

          private

          # Arguments are model-generated from the user's prompt and results
          # are provider or application data, so both are message content and
          # follow the same capture setting as the transcript.
          def execute_tool(tool_call)
            attributes = {
              "gen_ai.operation.name" => "execute_tool",
              "gen_ai.tool.name" => tool_call.name,
              "gen_ai.tool.call.id" => tool_call.id,
              "gen_ai.tool.type" => "function",
              "gen_ai.tool.description" => tools[tool_call.name.to_sym]&.description
            }.compact
            attributes["gen_ai.tool.call.arguments"] = truncate(tool_call.arguments.to_json) if capture_content?

            in_tool_span(tool_call, attributes) { super }
          end

          def in_tool_span(tool_call, attributes)
            tracer.in_span("execute_tool #{tool_call.name}",
                           attributes: attributes,
                           kind: OpenTelemetry::Trace::SpanKind::INTERNAL,
                           record_exception: false) do |span|
              begin
                result = yield
              rescue => e
                record_error(span, e)
                raise
              end

              if capture_content?
                # `RubyLLM::Tool::Halt#to_s` returns `@content.to_s`, so preserve
                # `to_s` for Halt (ruby_llm 1.x only; 2.0 removed it) and
                # plain-result cases while serializing hashes.
                safely do
                  tool_result = result.is_a?(Hash) ? result.to_json : result.to_s
                  span.set_attribute("gen_ai.tool.call.result", truncate(tool_result))
                end
              end

              result
            end
          end

          # Wraps one provider request: `complete` on 1.x, `generate` on 2.0.
          # On 2.0 a `generate` with fallbacks configured retries across models
          # inside this span, so `gen_ai.request.model` names the model the
          # request started on.
          def in_chat_span(streaming:)
            provider = @model&.provider || "unknown"
            model_id = @model&.id || "unknown"

            attributes = {
              "gen_ai.operation.name" => "chat",
              "gen_ai.provider.name" => provider,
              "gen_ai.request.model" => model_id,
            }
            conversation_id = otel_conversation_id
            attributes["gen_ai.conversation.id"] = conversation_id if conversation_id
            # Per GenAI semconv: set `gen_ai.request.stream` if and only if
            # the request is streaming. Absence means non-streaming.
            attributes["gen_ai.request.stream"] = true if streaming

            tracer.in_span("chat #{model_id}",
                           attributes: attributes,
                           kind: OpenTelemetry::Trace::SpanKind::CLIENT,
                           record_exception: false) do |span|
              begin
                result = yield
              rescue => e
                record_error(span, e)
                raise
              end

              safely { set_response_attributes(span) }

              result
            ensure
              set_custom_attributes(span)
            end
          end

          def set_response_attributes(span)
            response = @messages.last
            return unless response

            response_model = adapter.response_model(response)
            span.set_attribute("gen_ai.response.model", response_model) if response_model
            adapter.usage_attributes(response).each { |key, value| span.set_attribute(key, value) }
            span.set_attribute("gen_ai.request.temperature", @temperature) if @temperature

            return unless capture_content?

            system_messages = @messages.select { |m| m.role == :system }
            input_messages = @messages[0..-2].reject { |m| m.role == :system }

            unless system_messages.empty?
              span.set_attribute("gen_ai.system_instructions", MessageFormatter.format_system_instructions(system_messages, adapter))
            end

            span.set_attribute("gen_ai.input.messages", MessageFormatter.format_input_messages(input_messages, adapter))
            span.set_attribute("gen_ai.output.messages", MessageFormatter.format_output_messages([response], adapter))
          end
        end

        # 1.x: `complete` is one request and recurses, so a turn nests itself.
        module ChatComplete
          def complete(&)
            in_chat_span(streaming: block_given?) { super }
          end
        end

        # 2.0: `complete` became a loop, so the one request is `generate`,
        # which is also reachable on its own via `ask_later`.
        module ChatGenerate
          def generate(&)
            in_chat_span(streaming: block_given?) { super }
          end

          def complete(&)
            in_turn_span { super }
          end

          def step(&)
            in_turn_span { super }
          end

          def run_tools
            in_turn_span { super }
          end

          private

          # 2.0 runs tools between `generate` calls, so without this span a
          # turn is three sibling roots, i.e. three unrelated traces. Named
          # `invoke_agent` because the GenAI conventions define that as agent
          # invocation within the same process and prescribe it when no agent
          # name is available; `chat` stays reserved for exactly one provider
          # request on every version. Carries no usage, so nothing is counted
          # twice, but it is the trace root, so it must carry the custom
          # attributes that backends read at trace level.
          def in_turn_span
            return yield unless otel_turn_loops?
            # `Patches::Agent` already opened an `invoke_agent` span for this
            # turn; a second one would nest identically-named spans.
            return yield if agent_span_open? || turn_span_open?

            model_id = @model&.id || "unknown"
            attributes = {
              "gen_ai.operation.name" => "invoke_agent",
              "gen_ai.provider.name" => @model&.provider || "unknown",
              "gen_ai.request.model" => model_id
            }
            conversation_id = otel_conversation_id
            attributes["gen_ai.conversation.id"] = conversation_id if conversation_id

            with_turn_span_marker do
              tracer.in_span("invoke_agent #{model_id}",
                             attributes: attributes,
                             kind: OpenTelemetry::Trace::SpanKind::INTERNAL,
                             record_exception: false) do |span|
                yield
              rescue => e
                mark_error(span, e)
                raise
              ensure
                set_custom_attributes(span)
              end
            end
          end

          # Local tools are not the only thing that makes `complete` loop:
          # provider tools go back to `generate` after their results are
          # appended, with `tools` empty throughout. A chat with nothing
          # pending does not loop at all: `step` and `run_tools` return
          # without working, and wrapping that would export an empty span.
          def otel_turn_loops?
            return false if respond_to?(:complete?) && complete?
            return true if tools.any?

            respond_to?(:provider_tools) && provider_tools.any?
          end
        end
      end
    end
  end
end
