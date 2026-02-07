# frozen_string_literal: true

module OpenTelemetry
  module Instrumentation
    module RubyLLM
      module Patches
        module Chat
          def ask(message, &block)
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

          def tracer
            RubyLLM::Instrumentation.instance.tracer
          end
        end
      end
    end
  end
end
