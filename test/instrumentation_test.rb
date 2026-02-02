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
end
