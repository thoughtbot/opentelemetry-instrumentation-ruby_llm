# frozen_string_literal: true

module OpenTelemetry
  module Instrumentation
    module RubyLLM
      module Patches
        module Chat
          def ask(message = nil, with: nil, &)
            provider = @model&.provider || "unknown"
            model_id = @model&.id || "unknown"

            attributes = {
              "gen_ai.operation.name" => "chat",
              "gen_ai.provider.name" => provider,
              "gen_ai.request.model" => model_id,
            }

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

                if capture_content?
                  system_messages = @messages.select { |m| m.role == :system }
                  input_messages = @messages[0..-2].reject { |m| m.role == :system }

                  unless system_messages.empty?
                    span.set_attribute("gen_ai.system_instructions", format_system_instructions(system_messages))
                  end

                  span.set_attribute("gen_ai.input.messages", format_messages(input_messages))
                  span.set_attribute("gen_ai.output.messages", format_messages([response]))
                end
              end

              result
            end
          rescue StandardError => e
            OpenTelemetry.handle_error(exception: e)
            super
          end

          def execute_tool(tool_call)
            attributes = {
              "gen_ai.tool.name" => tool_call.name,
              "gen_ai.tool.call.id" => tool_call.id,
              "gen_ai.tool.call.arguments" => tool_call.arguments.to_json,
              "gen_ai.tool.type" => "function"
            }

            tracer.in_span("execute_tool #{tool_call.name}", attributes: attributes, kind: OpenTelemetry::Trace::SpanKind::INTERNAL) do |span|
              result = super
              result_str = result.is_a?(::RubyLLM::Tool::Halt) ? result.content.to_s : result.to_s
              span.set_attribute("gen_ai.tool.call.result", result_str[0..500])
              result
            end
          rescue StandardError => e
            OpenTelemetry.handle_error(exception: e)
            super
          end

          private

          def capture_content?
            env_value = ENV["OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"]
            return env_value.to_s.strip.casecmp("true").zero? unless env_value.nil?

            RubyLLM::Instrumentation.instance.config[:capture_content]
          end

          def format_messages(messages)
            messages.map { |m| format_message(m) }.to_json
          end

          def format_message(message)
            msg = { role: message.role.to_s, parts: [] }

            if message.content
              msg[:parts] << { type: "text", content: message.content.to_s }
            end

            if message.tool_calls&.any?
              message.tool_calls.each_value do |tc|
                msg[:parts] << { type: "tool_call", id: tc.id, name: tc.name, arguments: tc.arguments }
              end
            end

            msg[:tool_call_id] = message.tool_call_id if message.tool_call_id

            msg
          end

          def format_system_instructions(system_messages)
            system_messages.map { |m| { type: "text", content: m.content.to_s } }.to_json
          end

          def tracer
            RubyLLM::Instrumentation.instance.tracer
          end
        end
      end
    end
  end
end
