$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "webmock/minitest"
require "ruby_llm"
require "opentelemetry/sdk"
require "opentelemetry-instrumentation-ruby_llm"

module ChatCompletionStubs
  DEFAULT_USAGE = { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }.freeze

  def chat_completion_body(content: "Hello, world!", model: "gpt-4o-mini", tool_calls: nil, usage: DEFAULT_USAGE)
    message = { role: "assistant", content: content }
    message[:tool_calls] = tool_calls if tool_calls

    {
      id: "chatcmpl-123",
      object: "chat.completion",
      model: model,
      choices: [{
        index: 0,
        message: message,
        finish_reason: tool_calls ? "tool_calls" : "stop"
      }],
      usage: usage
    }.to_json
  end

  def stub_chat_completion(*bodies)
    bodies = [chat_completion_body] if bodies.empty?
    responses = bodies.map do |body|
      { status: 200, headers: { "Content-Type" => "application/json" }, body: body }
    end

    stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(*responses)
  end
end

EXPORTER = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
span_processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(EXPORTER)

OpenTelemetry::SDK.configure do |c|
  c.add_span_processor(span_processor)
  c.use "OpenTelemetry::Instrumentation::RubyLLM"
end
