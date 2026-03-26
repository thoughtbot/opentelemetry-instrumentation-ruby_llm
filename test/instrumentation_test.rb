require "test_helper"

class InstrumentationTest < Minitest::Test
  def setup
    EXPORTER.reset

    RubyLLM.configure do |c|
      c.openai_api_key = "fake-key-for-testing"
    end
  end

  def test_creates_span_with_attributes
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          id: "chatcmpl-123",
          object: "chat.completion",
          model: "gpt-4o-mini",
          choices: [
            {
              index: 0,
              message: { role: "assistant", content: "Hello, world!" },
              finish_reason: "stop"
            }
          ],
          usage: {
            prompt_tokens: 10,
            completion_tokens: 5,
            total_tokens: 15
          }
        }.to_json
      )

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
    assert_equal 10, span.attributes["gen_ai.usage.input_tokens"]
    assert_equal 5, span.attributes["gen_ai.usage.output_tokens"]
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

  def test_complete_still_works_when_instrumentation_fails
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          id: "chatcmpl-123",
          object: "chat.completion",
          model: "gpt-4o-mini",
          choices: [{
            index: 0,
            message: { role: "assistant", content: "Hello!" },
            finish_reason: "stop"
          }],
          usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
        }.to_json
      )

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.define_singleton_method(:tracer) { raise StandardError, "instrumentation bug" }

    response = chat.ask("Hi")
    assert_equal "Hello!", response.content
  end

  def test_instruments_complete_called_directly
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          id: "chatcmpl-123",
          object: "chat.completion",
          model: "gpt-4o-mini",
          choices: [{
            index: 0,
            message: { role: "assistant", content: "Hello, world!" },
            finish_reason: "stop"
          }],
          usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
        }.to_json
      )

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

    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(
        {
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            id: "chatcmpl-123",
            object: "chat.completion",
            model: "gpt-4o-mini",
            choices: [{
              index: 0,
              message: {
                role: "assistant",
                content: nil,
                tool_calls: [{
                  id: "call_abc123",
                  type: "function",
                  function: { name: "calculator", arguments: '{"expression":"2+2"}' }
                }]
              },
              finish_reason: "tool_calls"
            }],
            usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
          }.to_json
        },
        {
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            id: "chatcmpl-456",
            object: "chat.completion",
            model: "gpt-4o-mini",
            choices: [{
              index: 0,
              message: { role: "assistant", content: "The answer is 4" },
              finish_reason: "stop"
            }],
            usage: { prompt_tokens: 20, completion_tokens: 5, total_tokens: 25 }
          }.to_json
        }
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
    assert_equal "calculator", tool_span.attributes["gen_ai.tool.name"]
    assert_equal '{"expression":"2+2"}', tool_span.attributes["gen_ai.tool.call.arguments"]
    assert_equal "4", tool_span.attributes["gen_ai.tool.call.result"]
    assert_equal "call_abc123", tool_span.attributes["gen_ai.tool.call.id"]
    assert_equal "function", tool_span.attributes["gen_ai.tool.type"]
  end

  def test_execute_tool_still_works_when_instrumentation_fails
    calculator = Class.new(RubyLLM::Tool) do
      def self.name = "calculator"
      description "Performs math"
      param :expression, type: "string", desc: "Math expression"

      def execute(expression:)
        eval(expression).to_s
      end
    end

    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(
        {
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            id: "chatcmpl-123",
            object: "chat.completion",
            model: "gpt-4o-mini",
            choices: [{
              index: 0,
              message: {
                role: "assistant",
                content: nil,
                tool_calls: [{
                  id: "call_abc123",
                  type: "function",
                  function: { name: "calculator", arguments: '{"expression":"2+2"}' }
                }]
              },
              finish_reason: "tool_calls"
            }],
            usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
          }.to_json
        },
        {
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            id: "chatcmpl-456",
            object: "chat.completion",
            model: "gpt-4o-mini",
            choices: [{
              index: 0,
              message: { role: "assistant", content: "The answer is 4" },
              finish_reason: "stop"
            }],
            usage: { prompt_tokens: 20, completion_tokens: 5, total_tokens: 25 }
          }.to_json
        }
      )

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.with_tool(calculator)

    chat.define_singleton_method(:tracer) { raise StandardError, "instrumentation bug" }

    response = chat.ask("What is 2+2?")
    assert_equal "The answer is 4", response.content
  end

  def test_does_not_capture_content_by_default
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          id: "chatcmpl-123",
          object: "chat.completion",
          model: "gpt-4o-mini",
          choices: [{
            index: 0,
            message: { role: "assistant", content: "Hello, world!" },
            finish_reason: "stop"
          }],
          usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
        }.to_json
      )

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

    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          id: "chatcmpl-123",
          object: "chat.completion",
          model: "gpt-4o-mini",
          choices: [{
            index: 0,
            message: { role: "assistant", content: "Hello, world!" },
            finish_reason: "stop"
          }],
          usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
        }.to_json
      )

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

  def test_embed_still_works_when_instrumentation_fails
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

    mod = OpenTelemetry::Instrumentation::RubyLLM::Patches::Embedding
    original_tracer = mod.instance_method(:tracer)
    mod.define_method(:tracer) { raise StandardError, "instrumentation bug" }

    result = RubyLLM.embed("Hello, world!", model: "text-embedding-3-small")
    assert_equal [0.1, 0.2, 0.3], result.vectors
  ensure
    mod.define_method(:tracer, original_tracer)
  end

  def test_captures_content_when_enabled_via_env_var
    ENV["OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"] = "true"

    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          id: "chatcmpl-123",
          object: "chat.completion",
          model: "gpt-4o-mini",
          choices: [{
            index: 0,
            message: { role: "assistant", content: "Hello, world!" },
            finish_reason: "stop"
          }],
          usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
        }.to_json
      )

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
