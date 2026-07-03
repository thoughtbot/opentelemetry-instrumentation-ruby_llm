# frozen_string_literal: true

module OpenTelemetry
  module Instrumentation
    module RubyLLM
      module Patches
        module ChatMethods
          def to_llm(...)
            chat = super
            chat.otel_conversation_id = id.to_s if persisted?
            chat
          end
        end
      end
    end
  end
end
