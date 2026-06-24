# frozen_string_literal: true

module OpenTelemetry
  module Instrumentation
    module RubyLLM
      module Patches
        module Chat
          def with_otel_attributes(attributes)
            @otel_attributes = attributes
            self
          end

          def complete(&)
            provider = @model&.provider || "unknown"
            model_id = @model&.id || "unknown"

            attributes = {
              "gen_ai.operation.name" => "chat",
              "gen_ai.provider.name" => provider,
              "gen_ai.request.model" => model_id,
            }
            # Per GenAI semconv: set `gen_ai.request.stream` if and only if
            # the request is streaming. Absence means non-streaming.
            attributes["gen_ai.request.stream"] = true if block_given?

            tracer.in_span("chat #{model_id}", attributes: attributes, kind: OpenTelemetry::Trace::SpanKind::CLIENT) do |span|
              begin
                result = super
              rescue => e
                span.record_exception(e)
                span.status = OpenTelemetry::Trace::Status.error(e.message)
                span.set_attribute("error.type", e.class.name)
                raise
              end

              if @messages.last
                response = @messages.last
                span.set_attribute("gen_ai.response.model", response.model_id) if response.model_id
                span.set_attribute("gen_ai.usage.input_tokens", response.input_tokens) if response.input_tokens
                span.set_attribute("gen_ai.usage.output_tokens", response.output_tokens) if response.output_tokens
                span.set_attribute("gen_ai.request.temperature", @temperature) if @temperature

                # Prompt-cache token accessors were added in ruby_llm 1.9.0 (commit 869a755f).
                if response.respond_to?(:cached_tokens) && response.cached_tokens
                  span.set_attribute("gen_ai.usage.cache_read.input_tokens", response.cached_tokens)
                end

                # Prompt-cache token accessors were added in ruby_llm 1.9.0 (commit 869a755f).
                if response.respond_to?(:cache_creation_tokens) && response.cache_creation_tokens
                  span.set_attribute("gen_ai.usage.cache_creation.input_tokens", response.cache_creation_tokens)
                end

                if capture_content?
                  system_messages = @messages.select { |m| m.role == :system }
                  input_messages = @messages[0..-2].reject { |m| m.role == :system }

                  unless system_messages.empty?
                    span.set_attribute("gen_ai.system_instructions", MessageFormatter.format_system_instructions(system_messages))
                  end

                  span.set_attribute("gen_ai.input.messages", MessageFormatter.format_input_messages(input_messages))
                  span.set_attribute("gen_ai.output.messages", MessageFormatter.format_output_messages([response]))
                end
              end

              @otel_attributes&.each { |key, value| span.set_attribute(key, value.respond_to?(:call) ? value.call : value) }

              result
            end
          end

          def execute_tool(tool_call)
            attributes = {
              "gen_ai.operation.name" => "execute_tool",
              "gen_ai.tool.name" => tool_call.name,
              "gen_ai.tool.call.id" => tool_call.id,
              "gen_ai.tool.call.arguments" => tool_call.arguments.to_json,
              "gen_ai.tool.type" => "function",
              "gen_ai.tool.description" => tools[tool_call.name.to_sym]&.description
            }.compact

            tracer.in_span("execute_tool #{tool_call.name}", attributes: attributes, kind: OpenTelemetry::Trace::SpanKind::INTERNAL) do |span|
              begin
                result = super
              rescue => e
                span.record_exception(e)
                span.status = OpenTelemetry::Trace::Status.error(e.message)
                span.set_attribute("error.type", e.class.name)
                raise
              end

              # `RubyLLM::Tool::Halt#to_s` returns `@content.to_s`, so a single
              # `to_s` covers both the Halt and plain-result cases.
              span.set_attribute("gen_ai.tool.call.result", result.to_s[0, tool_result_max_length])

              result
            end
          end

          private

          def capture_content?
            env_value = ENV["OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"]
            return env_value.to_s.strip.casecmp("true").zero? unless env_value.nil?

            RubyLLM::Instrumentation.instance.config[:capture_content]
          end

          def tool_result_max_length
            RubyLLM::Instrumentation.instance.config[:tool_result_max_length]
          end

          def tracer
            RubyLLM::Instrumentation.instance.tracer
          end
        end
      end
    end
  end
end
