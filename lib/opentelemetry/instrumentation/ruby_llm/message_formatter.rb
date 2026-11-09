# frozen_string_literal: true

module OpenTelemetry
  module Instrumentation
    module RubyLLM
      # Converts `RubyLLM` messages and content into the JSON shape defined by
      # the GenAI semantic conventions for input/output messages and system
      # instructions:
      #
      #   https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/gen-ai-input-messages.json
      #   https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/gen-ai-output-messages.json
      #   https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/gen-ai-system-instructions.json
      #
      # Kept separate from the `RubyLLM::Chat` patch so the formatting logic
      # does not pollute the patched class. Only a message's parts differ
      # between ruby_llm majors, so those come from the version adapter.
      module MessageFormatter
        def self.format_input_messages(messages, adapter)
          messages.map { |m| format_message(m, adapter) }.to_json
        end

        def self.format_output_messages(messages, adapter)
          messages.map { |m| format_message(m, adapter) }.to_json
        end

        def self.format_system_instructions(messages, adapter)
          messages.flat_map { |m| adapter.content_parts(m) }.to_json
        end

        # Maps a `RubyLLM::Attachment` onto a GenAI message part. Public
        # because both adapters build parts from it; the accessors it reads
        # are unchanged between ruby_llm 1.x and 2.0.
        def self.attachment_part(attachment)
          part = { modality: attachment_modality(attachment) }
          part[:mime_type] = attachment.mime_type if attachment.mime_type

          if attachment.url?
            part[:type] = "uri"
            part[:uri] = attachment.source.to_s
          else
            part[:type] = "blob"
            part[:content] = attachment.source.to_s
          end

          part
        end

        # Caps a single part's payload. Provider-native content has no size
        # ceiling of its own, and an unbounded span attribute is dropped by
        # the collector along with the rest of its export batch.
        def self.bounded(value)
          limit = RubyLLM::Instrumentation.instance.config[:tool_result_max_length]
          limit = RubyLLM::Instrumentation::DEFAULT_TOOL_RESULT_MAX_LENGTH unless limit.is_a?(Integer) && limit.positive?
          value.to_s[0, limit]
        end

        private_class_method def self.format_message(message, adapter)
          msg = { role: message.role.to_s, parts: adapter.content_parts(message) }

          if message.tool_calls&.any?
            message.tool_calls.each_value do |tc|
              msg[:parts] << { type: "tool_call", id: tc.id, name: tc.name, arguments: tc.arguments }
            end
          end

          msg[:tool_call_id] = message.tool_call_id if message.tool_call_id

          msg
        end

        # Maps a `RubyLLM::Attachment#type` onto a GenAI modality. The symbol
        # vocabulary is the same in ruby_llm 1.x and 2.0.
        private_class_method def self.attachment_modality(attachment)
          case attachment.type
          when :image then "image"
          when :video then "video"
          when :audio then "audio"
          else "document"
          end
        end
      end
    end
  end
end
