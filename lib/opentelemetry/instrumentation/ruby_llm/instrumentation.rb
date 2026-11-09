# frozen_string_literal: true

module OpenTelemetry
  module Instrumentation
    module RubyLLM
      class Instrumentation < OpenTelemetry::Instrumentation::Base
        MINIMUM_RUBY_LLM_VERSION = "1.8.0"
        AGENT_MINIMUM_RUBY_LLM_VERSION = "1.12.1"
        DEFAULT_TOOL_RESULT_MAX_LENGTH = 500

        instrumentation_name "OpenTelemetry::Instrumentation::RubyLLM"
        instrumentation_version VERSION

        option :capture_content, default: false, validate: :boolean
        option :tool_result_max_length, default: DEFAULT_TOOL_RESULT_MAX_LENGTH, validate: :integer

        # The version adapter, bound once at install. Patches and the message
        # formatter read it from here rather than re-resolving it per span.
        attr_reader :adapter

        present do
          defined?(::RubyLLM)
        end

        compatible do
          require_relative "adapters"

          # The embedding patch calls `RubyLLM::Models.resolve` (class-method delegation added in 1.8.0);
          # Anything older than 1.8.0 would NoMethodError / NameError at install or first use.
          above_minimum = Gem::Version.new(::RubyLLM::VERSION) >= Gem::Version.new(MINIMUM_RUBY_LLM_VERSION)
          # Without this an unknown major installs and fails at the first chat.
          supported_major = Adapters.supports?(::RubyLLM::VERSION)

          unless above_minimum
            OpenTelemetry.logger.warn(
              "[OpenTelemetry::Instrumentation::RubyLLM] ruby_llm " \
              "#{::RubyLLM::VERSION} is below the required minimum " \
              "#{MINIMUM_RUBY_LLM_VERSION}; instrumentation will not be installed."
            )
          end

          if above_minimum && !supported_major
            OpenTelemetry.logger.warn(
              "[OpenTelemetry::Instrumentation::RubyLLM] ruby_llm " \
              "#{::RubyLLM::VERSION} is newer than the supported major " \
              "versions (#{Adapters::SUPPORTED_MAJORS.join(", ")}); upgrade " \
              "opentelemetry-instrumentation-ruby_llm or open an issue. " \
              "Instrumentation will not be installed."
            )
          end

          above_minimum && supported_major
        end

        install do |_config|
          require_relative "adapters"
          require_relative "message_formatter"
          require_relative "patches/chat"
          require_relative "patches/embedding"

          @adapter = Adapters.for_version(::RubyLLM::VERSION)

          # `Patches::Chat` carries the shared helpers, so it must sit behind
          # the version patch in the ancestor chain.
          ::RubyLLM::Chat.prepend(Patches::Chat)
          ::RubyLLM::Chat.prepend(self.class.chat_patch_for(::RubyLLM::VERSION))
          ::RubyLLM::Embedding.singleton_class.prepend(Patches::Embedding)

          if defined?(::RubyLLM::Agent) &&
             Gem::Version.new(::RubyLLM::VERSION) >= Gem::Version.new(AGENT_MINIMUM_RUBY_LLM_VERSION)
            require_relative "patches/agent"
            ::RubyLLM::Agent.prepend(Patches::Agent)
          end

          begin
            require "active_support/lazy_load_hooks"

            ::ActiveSupport.on_load(:active_record) do
              require "ruby_llm/active_record/chat_methods"
              require_relative "patches/chat_methods"
              ::RubyLLM::ActiveRecord::ChatMethods.prepend(Patches::ChatMethods)
            rescue LoadError
              OpenTelemetry.logger.warn(
                "[OpenTelemetry::Instrumentation::RubyLLM] could not load " \
                "ruby_llm/active_record/chat_methods; gen_ai.conversation.id " \
                "will not be set automatically on persisted chat records."
              )
            end
          rescue LoadError
            nil
          end
        end

        # Which patch wraps one provider request: `complete` recurses on 1.x,
        # while on 2.0 it loops over `generate`. Resolved after `install` has
        # required the patches.
        def self.chat_patch_for(version)
          {
            1 => Patches::ChatComplete,
            2 => Patches::ChatGenerate
          }.fetch(Gem::Version.new(version).segments.first)
        end
      end
    end
  end
end
