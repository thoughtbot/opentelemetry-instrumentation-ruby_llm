require "active_record"
require_relative "test_helper"

gem_dir = Gem.loaded_specs.fetch("ruby_llm").full_gem_path
Dir[File.join(gem_dir, "lib/ruby_llm/active_record/*.rb")].sort.each { |file| require file }

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Base.include RubyLLM::ActiveRecord::ActsAs

RubyLLM::Models.class_eval do
  if method_defined?(:load_models)
    def load_models
      read_from_json
    end
  else
    def self.load_models(file = RubyLLM.config.model_registry_file)
      read_from_json(file)
    end
  end
end

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :models do |t|
    t.string :model_id, null: false
    t.string :name, null: false
    t.string :provider, null: false
    t.string :family
    t.datetime :model_created_at
    t.integer :context_window
    t.integer :max_output_tokens
    t.date :knowledge_cutoff
    t.json :modalities, default: {}
    t.json :capabilities, default: []
    t.json :pricing, default: {}
    t.json :metadata, default: {}
    t.timestamps
  end

  create_table :chats do |t|
    t.references :model
    t.timestamps
  end

  create_table :messages do |t|
    t.string :role, null: false
    t.text :content
    t.json :content_raw
    t.text :thinking_text
    t.text :thinking_signature
    t.integer :thinking_tokens
    t.integer :input_tokens
    t.integer :output_tokens
    t.integer :cached_tokens
    t.integer :cache_creation_tokens
    t.references :chat, null: false
    t.references :model
    t.references :tool_call
    t.timestamps
  end

  create_table :tool_calls do |t|
    t.string :tool_call_id, null: false
    t.string :name, null: false
    t.text :thought_signature
    t.json :arguments, default: {}
    t.references :message, null: false
    t.timestamps
  end
end

class Model < ActiveRecord::Base
  acts_as_model
end

class Chat < ActiveRecord::Base
  acts_as_chat
end

class Message < ActiveRecord::Base
  acts_as_message
end

class ToolCall < ActiveRecord::Base
  acts_as_tool_call
end

if defined?(RubyLLM::Agent)
  class SupportAgent < RubyLLM::Agent
  end
end

class ActiveRecordChatMethodsTest < Minitest::Test
  include ChatCompletionStubs

  def setup
    EXPORTER.reset

    RubyLLM.configure do |c|
      c.openai_api_key = "fake-key-for-testing"
    end
  end

  def find_or_create_model
    Model.find_or_create_by!(model_id: "gpt-4o-mini", provider: "openai") do |m|
      m.name = "GPT-4o Mini"
    end
  end

  def create_chat_record
    Chat.create!(model: find_or_create_model)
  end

  def find_chat_span
    EXPORTER.finished_spans.find { |s| s.name.start_with?("chat ") }
  end

  def find_agent_span
    EXPORTER.finished_spans.find { |s| s.name.start_with?("invoke_agent") }
  end

  def test_persisted_record_ask_stamps_conversation_id_on_chat_span
    stub_chat_completion

    chat_record = create_chat_record
    chat_record.ask("Hi")

    assert_equal chat_record.id.to_s, find_chat_span.attributes["gen_ai.conversation.id"]
  end

  def test_plain_chat_span_carries_no_conversation_id
    stub_chat_completion

    RubyLLM.chat(model: "gpt-4o-mini").ask("Hi")

    assert_nil find_chat_span.attributes["gen_ai.conversation.id"]
  end

  def test_unpersisted_record_chat_is_not_stamped_until_persisted
    chat_record = Chat.new(model: find_or_create_model)

    assert_nil chat_record.to_llm.otel_conversation_id

    chat_record.save!

    assert_equal chat_record.id.to_s, chat_record.to_llm.otel_conversation_id
  end

  def test_user_otel_attributes_are_preserved_alongside_conversation_id
    stub_chat_completion

    chat_record = create_chat_record
    chat_record.to_llm.with_otel_attributes("enduser.id" => "user-1")
    chat_record.ask("Hi")

    span = find_chat_span
    assert_equal "user-1", span.attributes["enduser.id"]
    assert_equal chat_record.id.to_s, span.attributes["gen_ai.conversation.id"]
  end

  def test_user_supplied_conversation_id_wins_over_record_id
    stub_chat_completion

    chat_record = create_chat_record
    chat_record.to_llm.with_otel_attributes("gen_ai.conversation.id" => "custom-id")
    chat_record.ask("Hi")

    assert_equal "custom-id", find_chat_span.attributes["gen_ai.conversation.id"]
  end

  if defined?(RubyLLM::Agent)
    def test_agent_flow_carries_conversation_id_on_root_and_chat_spans
      stub_chat_completion

      chat_record = create_chat_record
      agent = SupportAgent.new(chat: chat_record)
      agent.ask("Hi")

      assert_equal chat_record.id.to_s, find_agent_span.attributes["gen_ai.conversation.id"]
      assert_equal chat_record.id.to_s, find_chat_span.attributes["gen_ai.conversation.id"]
    end

    def test_user_supplied_conversation_id_wins_on_agent_and_chat_spans
      stub_chat_completion

      chat_record = create_chat_record
      chat_record.to_llm.with_otel_attributes("gen_ai.conversation.id" => "custom-id")
      agent = SupportAgent.new(chat: chat_record)
      agent.ask("Hi")

      assert_equal "custom-id", find_agent_span.attributes["gen_ai.conversation.id"]
      assert_equal "custom-id", find_chat_span.attributes["gen_ai.conversation.id"]
    end
  end
end
