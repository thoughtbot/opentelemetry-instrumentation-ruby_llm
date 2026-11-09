# frozen_string_literal: true

require_relative "span_helpers"
require_relative "../message_formatter"

module OpenTelemetry
  module Instrumentation
    module RubyLLM
      module Patches
        module Agent
          include SpanHelpers

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
            conversation_id = llm_chat.otel_conversation_id if llm_chat.respond_to?(:otel_conversation_id)
            attributes["gen_ai.conversation.id"] = conversation_id if conversation_id

            span_name = agent_name ? "invoke_agent #{agent_name}" : "invoke_agent"

            # The marker keeps the 2.0 chat patch from opening a second
            # `invoke_agent` span for each turn inside this one.
            with_agent_span_marker do
              tracer.in_span(span_name,
                             attributes: attributes,
                             kind: OpenTelemetry::Trace::SpanKind::INTERNAL,
                             record_exception: false) do |span|
                result = yield
                safely { capture_messages(span) }
                result
              rescue => e
                mark_error(span, e)
                raise
              ensure
                set_custom_attributes(span)
              end
            end
          end

          def capture_messages(span)
            return unless capture_content?

            messages = llm_chat.messages
            return if messages.empty?

            input_messages = messages[0..-2].reject { |m| m.role == :system }
            span.set_attribute("gen_ai.input.messages", MessageFormatter.format_input_messages(input_messages, adapter))
            span.set_attribute("gen_ai.output.messages", MessageFormatter.format_output_messages([messages.last], adapter))
          end

          def llm_chat
            chat.respond_to?(:to_llm) ? chat.to_llm : chat
          end
        end
      end
    end
  end
end
