# frozen_string_literal: true

module OpenTelemetry
  module Instrumentation
    module RubyLLM
      class Instrumentation < OpenTelemetry::Instrumentation::Base
        instrumentation_name "OpenTelemetry::Instrumentation::RubyLLM"
        instrumentation_version VERSION

        option :capture_content, default: false, validate: :boolean

        present do
          defined?(::RubyLLM)
        end

        install do |_config|
          require_relative "patches/chat"
          require_relative "patches/embedding"
          ::RubyLLM::Chat.prepend(Patches::Chat)
          ::RubyLLM::Embedding.singleton_class.prepend(Patches::Embedding)
        end
      end
    end
  end
end
