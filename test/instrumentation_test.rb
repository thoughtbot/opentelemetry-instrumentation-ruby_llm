require "test_helper"

class InstrumentationTest < Minitest::Test
  include ChatCompletionStubs

  def setup
    EXPORTER.reset

    RubyLLM.configure do |c|
      c.openai_api_key = "fake-key-for-testing"
      c.anthropic_api_key = "fake-key-for-testing"
    end
  end

  def test_compatible_is_true_for_current_ruby_llm_version
    instrumentation = OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance
    assert_equal true, instrumentation.compatible?
  end

  def test_compatible_is_false_when_ruby_llm_below_minimum
    original_version = ::RubyLLM::VERSION
    ::RubyLLM.send(:remove_const, :VERSION)
    ::RubyLLM.const_set(:VERSION, "1.7.99")

    instrumentation = OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance
    assert_equal false, instrumentation.compatible?
  ensure
    ::RubyLLM.send(:remove_const, :VERSION)
    ::RubyLLM.const_set(:VERSION, original_version)
  end

  def test_minimum_ruby_llm_version_is_pinned_at_1_8_0
    assert_equal "1.8.0", OpenTelemetry::Instrumentation::RubyLLM::Instrumentation::MINIMUM_RUBY_LLM_VERSION
  end

  def test_agent_minimum_ruby_llm_version_is_pinned_at_1_12_1
    assert_equal "1.12.1", OpenTelemetry::Instrumentation::RubyLLM::Instrumentation::AGENT_MINIMUM_RUBY_LLM_VERSION
  end

  def test_creates_span_with_attributes
    stub_chat_completion

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.ask("Hi")

    spans = EXPORTER.finished_spans
    assert_equal 1, spans.length

    span = spans.first
    assert_equal OpenTelemetry::Trace::SpanKind::CLIENT, span.kind
    assert_equal "chat gpt-4o-mini", span.name
    assert_equal "openai", span.attributes["gen_ai.provider.name"]
    assert_equal "gpt-4o-mini", span.attributes["gen_ai.request.model"]
    assert_equal "chat", span.attributes["gen_ai.operation.name"]
    # Per GenAI semconv, `gen_ai.request.stream` is set only when streaming.
    assert_nil span.attributes["gen_ai.request.stream"]
    assert_equal 10, span.attributes["gen_ai.usage.input_tokens"]
    assert_equal 5, span.attributes["gen_ai.usage.output_tokens"]
  end

  def test_marks_streaming_chat_requests
    stub_chat_completion(
      chat_completion_body(content: "Hi", usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 })
    )

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.ask("Hi") { |_chunk| }

    span = EXPORTER.finished_spans.first
    assert_equal true, span.attributes["gen_ai.request.stream"]
  end

  def test_records_openai_prompt_cache_read_tokens
    # OpenAI exposes only `cached_tokens` via `prompt_tokens_details.cached_tokens`.
    # Its provider in ruby_llm does not surface a `cache_creation_tokens` value
    # until 1.15.0 (we only assert the cache-read attribute here).
    # The accessor itself was added in ruby_llm 1.9.0.
    skip "cached_tokens accessor not available before ruby_llm 1.9.0" unless RubyLLM::Message.instance_methods.include?(:cached_tokens)
    stub_chat_completion(
      chat_completion_body(
        content: "Hello!",
        usage: {
          prompt_tokens: 100,
          completion_tokens: 5,
          total_tokens: 105,
          prompt_tokens_details: { cached_tokens: 75 }
        }
      )
    )

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.ask("Hi")

    span = EXPORTER.finished_spans.first
    assert_equal 75, span.attributes["gen_ai.usage.cache_read.input_tokens"]
    assert_equal 0, span.attributes["gen_ai.usage.cache_creation.input_tokens"]
  end

  def test_records_anthropic_prompt_cache_tokens
    # Anthropic's provider surfaces both `cached_tokens` (via
    # `cache_read_input_tokens`) and `cache_creation_tokens` (via
    # `cache_creation_input_tokens`). Accessors were added in ruby_llm 1.9.0.
    skip "cache token accessors not available before ruby_llm 1.9.0" unless RubyLLM::Message.instance_methods.include?(:cache_creation_tokens)
    stub_request(:post, "https://api.anthropic.com/v1/messages")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          id: "msg_cache",
          type: "message",
          role: "assistant",
          model: "claude-3-5-sonnet-20241022",
          content: [{ type: "text", text: "Hello!" }],
          stop_reason: "end_turn",
          usage: {
            input_tokens: 100,
            output_tokens: 5,
            cache_read_input_tokens: 75,
            cache_creation_input_tokens: 20
          }
        }.to_json
      )

    chat = RubyLLM.chat(model: "claude-3-5-sonnet-20241022")
    chat.ask("Hi")

    span = EXPORTER.finished_spans.first
    assert_equal 75, span.attributes["gen_ai.usage.cache_read.input_tokens"]
    assert_equal 20, span.attributes["gen_ai.usage.cache_creation.input_tokens"]
  end

  def test_records_error_on_api_failure
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 500, body: "Internal Server Error")

    chat = RubyLLM.chat(model: "gpt-4o-mini")

    assert_raises do
      chat.ask("Hi")
    end

    spans = EXPORTER.finished_spans
    span = spans.last

    assert_equal "chat gpt-4o-mini", span.name
    assert span.attributes["error.type"]
    assert_equal OpenTelemetry::Trace::Status::ERROR, span.status.code
  end

  def test_instruments_complete_called_directly
    stub_chat_completion

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.add_message(role: :user, content: "Hi")
    chat.complete

    spans = EXPORTER.finished_spans
    assert_equal 1, spans.length

    span = spans.first
    assert_equal "chat gpt-4o-mini", span.name
    assert_equal "chat", span.attributes["gen_ai.operation.name"]
    assert_equal "openai", span.attributes["gen_ai.provider.name"]
    assert_equal 10, span.attributes["gen_ai.usage.input_tokens"]
    assert_equal 5, span.attributes["gen_ai.usage.output_tokens"]
  end

  def test_creates_span_for_tool_call
    calculator = Class.new(RubyLLM::Tool) do
      def self.name = "calculator"
      description "Performs math"
      param :expression, type: "string", desc: "Math expression"

      def execute(expression:)
        eval(expression).to_s
      end
    end

    stub_chat_completion(
      chat_completion_body(
        content: nil,
        tool_calls: [{
          id: "call_abc123",
          type: "function",
          function: { name: "calculator", arguments: '{"expression":"2+2"}' }
        }]
      ),
      chat_completion_body(
        content: "The answer is 4",
        usage: { prompt_tokens: 20, completion_tokens: 5, total_tokens: 25 }
      )
    )

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.with_tool(calculator)
    chat.ask("What is 2+2?")

    spans = EXPORTER.finished_spans

    tool_spans = spans.select { |s| s.name.start_with?("execute_tool ") }
    chat_spans = spans.select { |s| s.name.include?("chat ") }

    assert_equal 1, tool_spans.length
    assert_equal 2, chat_spans.length

    tool_span = tool_spans.first
    assert_equal OpenTelemetry::Trace::SpanKind::INTERNAL, tool_span.kind
    assert_equal "execute_tool calculator", tool_span.name
    assert_equal "execute_tool", tool_span.attributes["gen_ai.operation.name"]
    assert_equal "calculator", tool_span.attributes["gen_ai.tool.name"]
    assert_equal "Performs math", tool_span.attributes["gen_ai.tool.description"]
    assert_equal '{"expression":"2+2"}', tool_span.attributes["gen_ai.tool.call.arguments"]
    assert_equal "4", tool_span.attributes["gen_ai.tool.call.result"]
    assert_equal "call_abc123", tool_span.attributes["gen_ai.tool.call.id"]
    assert_equal "function", tool_span.attributes["gen_ai.tool.type"]
  end

  def test_truncates_tool_result_to_configured_max_length
    long_value = "x" * 1000
    echo = Class.new(RubyLLM::Tool) do
      def self.name = "echo"
      description "Echoes a long string"

      define_method(:execute) { long_value }
    end

    stub_chat_completion(
      chat_completion_body(
        content: nil,
        tool_calls: [{
          id: "call_echo",
          type: "function",
          function: { name: "echo", arguments: "{}" }
        }]
      ),
      chat_completion_body(
        content: "done",
        usage: { prompt_tokens: 20, completion_tokens: 5, total_tokens: 25 }
      )
    )

    OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:tool_result_max_length] = 700

    chat = RubyLLM.chat(model: "gpt-4o-mini").with_tool(echo)
    chat.ask("echo please")

    tool_span = EXPORTER.finished_spans.find { |s| s.name.start_with?("execute_tool ") }
    assert_equal "x" * 700, tool_span.attributes["gen_ai.tool.call.result"]
  ensure
    OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:tool_result_max_length] = 500
  end

  def test_records_error_when_tool_raises
    boom = Class.new(RubyLLM::Tool) do
      def self.name = "boom"
      description "Always raises"

      def execute
        raise ArgumentError, "tool failure"
      end
    end

    stub_chat_completion(
      chat_completion_body(
        content: nil,
        tool_calls: [{
          id: "call_x",
          type: "function",
          function: { name: "boom", arguments: "{}" }
        }],
        usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 }
      )
    )

    chat = RubyLLM.chat(model: "gpt-4o-mini").with_tool(boom)
    assert_raises(ArgumentError) { chat.ask("trigger") }

    tool_span = EXPORTER.finished_spans.find { |s| s.name.start_with?("execute_tool ") }
    assert_equal "ArgumentError", tool_span.attributes["error.type"]
    assert_equal OpenTelemetry::Trace::Status::ERROR, tool_span.status.code
  end

  def test_does_not_capture_content_by_default
    stub_chat_completion

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.with_instructions("You are helpful")
    chat.ask("Hi")

    span = EXPORTER.finished_spans.first
    assert_nil span.attributes["gen_ai.system_instructions"]
    assert_nil span.attributes["gen_ai.input.messages"]
    assert_nil span.attributes["gen_ai.output.messages"]
  end

  def test_captures_content_when_enabled
    OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:capture_content] = true

    stub_chat_completion

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.with_instructions("You are helpful")
    chat.ask("Hi")

    span = EXPORTER.finished_spans.first

    system_instructions = JSON.parse(span.attributes["gen_ai.system_instructions"])
    assert_equal [{ "type" => "text", "content" => "You are helpful" }], system_instructions

    input_messages = JSON.parse(span.attributes["gen_ai.input.messages"])
    assert_equal 1, input_messages.length
    assert_equal "user", input_messages[0]["role"]
    assert_equal [{ "type" => "text", "content" => "Hi" }], input_messages[0]["parts"]

    output_messages = JSON.parse(span.attributes["gen_ai.output.messages"])
    assert_equal 1, output_messages.length
    assert_equal "assistant", output_messages[0]["role"]
    assert_equal [{ "type" => "text", "content" => "Hello, world!" }], output_messages[0]["parts"]
  ensure
    OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:capture_content] = false
  end

  def test_creates_span_for_embedding
    stub_request(:post, "https://api.openai.com/v1/embeddings")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          object: "list",
          model: "text-embedding-3-small",
          data: [
            { object: "embedding", index: 0, embedding: [0.1, 0.2, 0.3] }
          ],
          usage: { prompt_tokens: 8, total_tokens: 8 }
        }.to_json
      )

    RubyLLM.embed("Hello, world!", model: "text-embedding-3-small")

    spans = EXPORTER.finished_spans
    assert_equal 1, spans.length

    span = spans.first
    assert_equal OpenTelemetry::Trace::SpanKind::CLIENT, span.kind
    assert_equal "embeddings text-embedding-3-small", span.name
    assert_equal "embeddings", span.attributes["gen_ai.operation.name"]
    assert_equal "openai", span.attributes["gen_ai.provider.name"]
    assert_equal "text-embedding-3-small", span.attributes["gen_ai.request.model"]
    assert_equal "text-embedding-3-small", span.attributes["gen_ai.response.model"]
    assert_equal 8, span.attributes["gen_ai.usage.input_tokens"]
    assert_equal 3, span.attributes["gen_ai.embeddings.dimension.count"]
  end

  def test_records_error_on_embedding_api_failure
    stub_request(:post, "https://api.openai.com/v1/embeddings")
      .to_return(status: 500, body: "Internal Server Error")

    assert_raises do
      RubyLLM.embed("Hello", model: "text-embedding-3-small")
    end

    spans = EXPORTER.finished_spans
    span = spans.last

    assert_equal "embeddings text-embedding-3-small", span.name
    assert span.attributes["error.type"]
    assert_equal OpenTelemetry::Trace::Status::ERROR, span.status.code
  end

  def test_with_otel_attributes_sets_span_attributes
    stub_chat_completion(chat_completion_body(content: "Hello!"))

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.with_otel_attributes(
      "langfuse.trace.tags" => ["vitamin_d3"],
      "custom.category" => "supplements"
    )
    chat.ask("Hi")

    span = EXPORTER.finished_spans.first
    assert_equal ["vitamin_d3"], span.attributes["langfuse.trace.tags"]
    assert_equal "supplements", span.attributes["custom.category"]
  end

  def test_with_otel_attributes_returns_self_for_chaining
    stub_chat_completion(chat_completion_body(content: "Hello!"))

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    result = chat.with_otel_attributes("custom.category" => "test")

    assert_same chat, result
  end

  def test_with_otel_attributes_evaluates_callables
    stub_chat_completion(chat_completion_body(content: "Hello!"))

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.with_otel_attributes(
      "custom.last_role" => -> { chat.messages.last&.role.to_s },
      "custom.static" => "fixed"
    )
    chat.ask("Hi")

    span = EXPORTER.finished_spans.first
    assert_equal "assistant", span.attributes["custom.last_role"]
    assert_equal "fixed", span.attributes["custom.static"]
  end

  def test_works_without_otel_attributes
    stub_chat_completion(chat_completion_body(content: "Hello!"))

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    response = chat.ask("Hi")

    assert_equal "Hello!", response.content
  end

  def test_captures_ruby_llm_content_with_attachments
    OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:capture_content] = true

    stub_chat_completion(chat_completion_body(content: "A cat."))

    content = RubyLLM::Content.new("What is this?", "https://example.com/cat.png")

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.add_message(role: :user, content: content)
    chat.complete

    span = EXPORTER.finished_spans.first
    input_messages = JSON.parse(span.attributes["gen_ai.input.messages"])
    assert_equal(
      [
        { "type" => "text", "content" => "What is this?" },
        {
          "type" => "uri",
          "modality" => "image",
          "mime_type" => "image/png",
          "uri" => "https://example.com/cat.png"
        }
      ],
      input_messages[0]["parts"]
    )
  ensure
    OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:capture_content] = false
  end

  def test_captures_ruby_llm_content_raw
    skip "RubyLLM::Content::Raw not available before ruby_llm 1.9.0" unless defined?(RubyLLM::Content::Raw)
    OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:capture_content] = true

    stub_chat_completion(chat_completion_body(content: "Acknowledged."))

    raw = RubyLLM::Content::Raw.new([{ type: "text", text: "raw payload" }])

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.add_message(role: :user, content: raw)
    chat.complete

    span = EXPORTER.finished_spans.first
    input_messages = JSON.parse(span.attributes["gen_ai.input.messages"])
    assert_equal(
      [{ "type" => "raw", "content" => [{ "type" => "text", "text" => "raw payload" }].to_json }],
      input_messages[0]["parts"]
    )
  ensure
    OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:capture_content] = false
  end

  def test_captures_ruby_llm_content_raw_system_instructions
    skip "RubyLLM::Content::Raw not available before ruby_llm 1.9.0" unless defined?(RubyLLM::Content::Raw)
    OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:capture_content] = true

    stub_chat_completion(chat_completion_body(content: "Acknowledged."))

    raw_block = RubyLLM::Content::Raw.new([{ type: "text", text: "You are helpful" }])

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.add_message(role: :system, content: raw_block)
    chat.add_message(role: :user, content: "Hi")
    chat.complete

    span = EXPORTER.finished_spans.first
    system_instructions = JSON.parse(span.attributes["gen_ai.system_instructions"])
    assert_equal(
      [{ "type" => "raw", "content" => [{ "type" => "text", "text" => "You are helpful" }].to_json }],
      system_instructions
    )
  ensure
    OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:capture_content] = false
  end

  def test_captures_content_when_enabled_via_env_var
    ENV["OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"] = "true"

    stub_chat_completion

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.ask("Hi")

    span = EXPORTER.finished_spans.first

    input_messages = JSON.parse(span.attributes["gen_ai.input.messages"])
    assert_equal "user", input_messages[0]["role"]

    output_messages = JSON.parse(span.attributes["gen_ai.output.messages"])
    assert_equal "assistant", output_messages[0]["role"]
  ensure
    ENV.delete("OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT")
  end
end
