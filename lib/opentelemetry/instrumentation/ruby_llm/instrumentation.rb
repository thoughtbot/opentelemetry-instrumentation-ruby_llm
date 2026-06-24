# frozen_string_literal: true

module OpenTelemetry
  module Instrumentation
    module RubyLLM
      class Instrumentation < OpenTelemetry::Instrumentation::Base
        MINIMUM_RUBY_LLM_VERSION = "1.8.0"

        instrumentation_name "OpenTelemetry::Instrumentation::RubyLLM"
        instrumentation_version VERSION

        option :capture_content, default: false, validate: :boolean
        option :tool_result_max_length, default: 500, validate: :integer

        present do
          defined?(::RubyLLM)
        end

        compatible do
          # The embedding patch calls `RubyLLM::Models.resolve` (class-method delegation added in 1.8.0);
          # Anything older than 1.8.0 would NoMethodError / NameError at install or first use.
          compatible = Gem::Version.new(::RubyLLM::VERSION) >= Gem::Version.new(MINIMUM_RUBY_LLM_VERSION)

          unless compatible
            OpenTelemetry.logger.warn(
              "[OpenTelemetry::Instrumentation::RubyLLM] ruby_llm " \
              "#{::RubyLLM::VERSION} is below the required minimum " \
              "#{MINIMUM_RUBY_LLM_VERSION}; instrumentation will not be installed."
            )
          end

          compatible
        end

        install do |_config|
          require_relative "message_formatter"
          require_relative "patches/chat"
          require_relative "patches/embedding"
          ::RubyLLM::Chat.prepend(Patches::Chat)
          ::RubyLLM::Embedding.singleton_class.prepend(Patches::Embedding)
        end
      end
    end
  end
end
