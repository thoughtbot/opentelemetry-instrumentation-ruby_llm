# frozen_string_literal: true

module OpenTelemetry
  module Instrumentation
    module RubyLLM
      module Patches
        module Agent
          def with_otel_attributes(attributes)
            @otel_attributes = attributes
            llm_chat.with_otel_attributes(attributes)
            self
          end

          def ask(...)
            in_invoke_agent_span { super }
          end

          def say(...)
            in_invoke_agent_span { super }
          end

          def complete(...)
            in_invoke_agent_span { super }
          end

          private

          def in_invoke_agent_span
            agent_name = self.class.name
            attributes = { "gen_ai.operation.name" => "invoke_agent" }
            attributes["gen_ai.agent.name"] = agent_name if agent_name
            attributes["gen_ai.conversation.id"] = chat.id.to_s if chat.respond_to?(:persisted?) && chat.persisted?

            span_name = agent_name ? "invoke_agent #{agent_name}" : "invoke_agent"

            tracer.in_span(span_name, attributes: attributes, kind: OpenTelemetry::Trace::SpanKind::INTERNAL) do |span|
              result = yield
              capture_messages(span)
              result
            rescue => e
              span.set_attribute("error.type", e.class.name)
              raise
            ensure
              set_custom_attributes(span)
            end
          end

          def capture_messages(span)
            return unless capture_content?

            messages = llm_chat.messages
            return if messages.empty?

            input_messages = messages[0..-2].reject { |m| m.role == :system }
            span.set_attribute("gen_ai.input.messages", MessageFormatter.format_input_messages(input_messages))
            span.set_attribute("gen_ai.output.messages", MessageFormatter.format_output_messages([messages.last]))
          end

          def llm_chat
            chat.respond_to?(:to_llm) ? chat.to_llm : chat
          end

          def capture_content?
            env_value = ENV["OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"]
            return env_value.to_s.strip.casecmp("true").zero? unless env_value.nil?

            RubyLLM::Instrumentation.instance.config[:capture_content]
          end

          def set_custom_attributes(span)
            @otel_attributes&.each { |key, value| span.set_attribute(key, value.respond_to?(:call) ? value.call : value) }
          rescue => e
            OpenTelemetry.handle_error(exception: e)
          end

          def tracer
            RubyLLM::Instrumentation.instance.tracer
          end
        end
      end
    end
  end
end
