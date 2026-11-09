# frozen_string_literal: true

module OpenTelemetry
  module Instrumentation
    module RubyLLM
      module Patches
        # Set while an `invoke_agent` span is open so the 2.0 chat patch can
        # tell that the turn it is about to wrap already has one.
        AGENT_SPAN_KEY = OpenTelemetry::Context.create_key("ruby_llm.agent_span")

        TURN_SPAN_KEY = OpenTelemetry::Context.create_key("ruby_llm.turn_span")

        # Span plumbing shared by the chat, agent and embedding patches: the
        # tracer, the version adapter, the two capture settings, and the
        # writers for custom attributes and errors.
        module SpanHelpers
          private

          def agent_span_open?
            !OpenTelemetry::Context.current[AGENT_SPAN_KEY].nil?
          end

          def with_agent_span_marker(&)
            OpenTelemetry::Context.with_value(AGENT_SPAN_KEY, true, &)
          end

          def turn_span_open?
            !OpenTelemetry::Context.current[TURN_SPAN_KEY].nil?
          end

          def with_turn_span_marker(&)
            OpenTelemetry::Context.with_value(TURN_SPAN_KEY, true, &)
          end

          def tracer
            RubyLLM::Instrumentation.instance.tracer
          end

          def adapter
            RubyLLM::Instrumentation.instance.adapter
          end

          def capture_content?
            env_value = ENV["OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"]
            return env_value.strip.casecmp?("true") unless env_value.nil?

            RubyLLM::Instrumentation.instance.config[:capture_content]
          end

          # `String#[]` answers "" for a length of 0 and nil for a negative
          # one, so a non-positive limit would blank the attribute rather
          # than mean "no limit". Fall back to the configured value, then to
          # the option default.
          def content_max_length
            parsed = Integer(ENV["OTEL_INSTRUMENTATION_GENAI_TOOL_RESULT_MAX_LENGTH"].to_s.strip, exception: false)
            return parsed if parsed&.positive?

            configured = RubyLLM::Instrumentation.instance.config[:tool_result_max_length]
            configured.is_a?(Integer) && configured.positive? ? configured : RubyLLM::Instrumentation::DEFAULT_TOOL_RESULT_MAX_LENGTH
          end

          def truncate(value)
            value.to_s[0, content_max_length]
          end

          # Values may be callables supplied by the caller. This runs from an
          # `ensure`, where a raise would both escape into the caller's
          # request and discard the exception already in flight.
          def set_custom_attributes(span)
            @otel_attributes&.each { |key, value| span.set_attribute(key, value.respond_to?(:call) ? value.call : value) }
          rescue => e
            OpenTelemetry.handle_error(exception: e)
          end

          # Attribute reads go through ruby_llm accessors that move between
          # minors, which a major-level compatibility gate cannot cover. A
          # failure costs the attributes, not the caller's request.
          def safely
            yield
          rescue => e
            OpenTelemetry.handle_error(exception: e)
          end

          # `RubyLLM::Error#message` falls back to the raw response body when
          # the provider's error payload cannot be parsed, so the message can
          # carry the request a gateway echoed back. The type and backtrace
          # carry no request data and are always recorded; the message needs
          # content capture.
          def record_error(span, error)
            span.set_attribute("error.type", error.class.name)

            if capture_content?
              span.record_exception(error)
              span.status = OpenTelemetry::Trace::Status.error(error.message)
            else
              span.add_event(
                "exception",
                attributes: {
                  "exception.type" => error.class.name,
                  "exception.stacktrace" => error.backtrace&.join("\n").to_s
                }
              )
              span.status = OpenTelemetry::Trace::Status.error(error.class.name)
            end
          end

          # The failing operation's own span records the exception; this
          # only carries it outward.
          def mark_error(span, error)
            span.set_attribute("error.type", error.class.name)
            span.status = OpenTelemetry::Trace::Status.error(error.class.name)
          end
        end
      end
    end
  end
end
