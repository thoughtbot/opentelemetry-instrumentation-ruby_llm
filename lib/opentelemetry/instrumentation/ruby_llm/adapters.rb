# frozen_string_literal: true

require_relative "message_formatter"

module OpenTelemetry
  module Instrumentation
    module RubyLLM
      # One adapter per supported ruby_llm major, chosen at install.
      #
      # Each adapter answers the five reads that moved between majors:
      # `response_model`, `usage_attributes`, `resolve_model`,
      # `embedding_input_tokens` and `content_parts`. Which patch wraps the
      # chat is a structural decision and belongs to the instrumentation,
      # not here.
      module Adapters
        class << self
          # Discriminates on the major segment, not `>=`: a prerelease sorts
          # below the release it leads to, so `2.0.0.rc1 >= 2.0` is false and
          # a `>=` test would hand it the 1.x adapter.
          def for_version(version)
            ADAPTERS[Gem::Version.new(version).segments.first]
          rescue ArgumentError
            # A version string ruby_llm never published. Unsupported rather
            # than fatal, so the `compatible` gate can decline in peace.
            nil
          end

          def supports?(version)
            !for_version(version).nil?
          end
        end

        module V1
          def self.response_model(message)
            message.model_id
          end

          def self.usage_attributes(message)
            attributes = {
              "gen_ai.usage.input_tokens" => message.input_tokens,
              "gen_ai.usage.output_tokens" => message.output_tokens
            }

            # Prompt-cache token accessors were added in ruby_llm 1.9.0.
            if message.respond_to?(:cached_tokens)
              attributes["gen_ai.usage.cache_read.input_tokens"] = message.cached_tokens
            end

            if message.respond_to?(:cache_creation_tokens)
              attributes["gen_ai.usage.cache_creation.input_tokens"] = message.cache_creation_tokens
            end

            attributes.compact
          end

          def self.resolve_model(model_id, provider:, assume_model_exists:, config:)
            ::RubyLLM::Models.resolve(
              model_id, provider: provider, assume_exists: assume_model_exists, config: config
            ).first
          end

          def self.embedding_input_tokens(result)
            result.input_tokens
          end

          def self.content_parts(message)
            content = message.content
            return [] if content.nil?

            # `RubyLLM::Content::Raw` was added in ruby_llm 1.9.0, so guard
            # the constant rather than referencing it in a `case`/`when`.
            if defined?(::RubyLLM::Content::Raw) && content.is_a?(::RubyLLM::Content::Raw)
              # A provider-native payload, which for image and document
              # blocks holds base64 bytes. Serialized so consumers render it
              # as text rather than `[object Object]`, and bounded because
              # the payload has no size ceiling of its own.
              [{ type: "raw", content: MessageFormatter.bounded(content.value.to_json) }]
            elsif content.is_a?(::RubyLLM::Content)
              parts = []
              parts << { type: "text", content: content.text } unless content.text.nil?
              parts.concat(content.attachments.map { |a| MessageFormatter.attachment_part(a) })
            else
              # An assistant message that only requests tool calls carries an
              # empty string, which is not text and must not become a part.
              text = content.to_s
              text.empty? ? [] : [{ type: "text", content: text }]
            end
          end
        end

        module V2
          def self.response_model(message)
            message.model
          end

          def self.usage_attributes(message)
            tokens = message.tokens
            return {} unless tokens

            {
              "gen_ai.usage.input_tokens" => tokens.input,
              "gen_ai.usage.output_tokens" => tokens.output,
              "gen_ai.usage.cache_read.input_tokens" => tokens.cache_read,
              "gen_ai.usage.cache_creation.input_tokens" => tokens.cache_write
            }.compact
          end

          def self.resolve_model(model_id, provider:, assume_model_exists:, config:)
            ::RubyLLM::Models.resolve(
              model_id, provider: provider, assume_model_exists: assume_model_exists, config: config
            ).first
          end

          def self.embedding_input_tokens(result)
            result.tokens&.input
          end

          def self.content_parts(message)
            content = message.content
            # An assistant message that only requests tool calls carries an
            # empty string here, where 1.x carries nil. Both mean "no text".
            parts = content.nil? || content.empty? ? [] : [{ type: "text", content: content }]
            parts.concat(message.attachments.map { |a| MessageFormatter.attachment_part(a) })
          end
        end

        # A major missing here is refused by the `compatible` gate.
        ADAPTERS = { 1 => V1, 2 => V2 }.freeze
        SUPPORTED_MAJORS = ADAPTERS.keys.freeze
      end
    end
  end
end
