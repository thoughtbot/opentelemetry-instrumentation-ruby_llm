$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "webmock/minitest"
require "ruby_llm"
require "opentelemetry/sdk"
require "opentelemetry-instrumentation-ruby_llm"

# ruby_llm 2.0 renamed or removed enough of the surface these tests touch that
# a single version check, computed once here, beats scattering comparisons
# across the suite.
RUBY_LLM_V2 = Gem::Version.new(RubyLLM::VERSION) >= Gem::Version.new("2.0")

# Model ids age out of ruby_llm's bundled registry: 2.0 no longer ships
# `claude-3-5-sonnet-20241022`, and 1.x does not yet know `claude-sonnet-4-5`.
ANTHROPIC_MODEL = RUBY_LLM_V2 ? "claude-sonnet-4-5" : "claude-3-5-sonnet-20241022"

# `Tool.param(name, type:, desc:)` became `Tool.parameter(name, type:,
# description:)` in ruby_llm 2.0, with no alias either way. One shim keeps the
# tool classes in these tests readable on both majors.
module ToolParameterCompat
  def tool_parameter(name, type:, description:)
    if RUBY_LLM_V2
      parameter(name, type: type, description: description)
    else
      param(name, type: type, desc: description)
    end
  end
end
RubyLLM::Tool.singleton_class.include(ToolParameterCompat)

module ChatCompletionStubs
  # ruby_llm 1.x drives OpenAI through the Chat Completions API; 2.0 defaults
  # it to the Responses API. Both are stubbed from the same protocol-neutral
  # description of a turn so every call site stays version-agnostic.
  CHAT_COMPLETIONS_URL = "https://api.openai.com/v1/chat/completions"
  RESPONSES_URL = "https://api.openai.com/v1/responses"

  DEFAULT_USAGE = { input_tokens: 10, output_tokens: 5 }.freeze

  def openai_chat_url
    RUBY_LLM_V2 ? RESPONSES_URL : CHAT_COMPLETIONS_URL
  end

  # Describes one assistant turn and renders it into whichever OpenAI wire
  # format the installed ruby_llm speaks.
  #
  # `usage:` is protocol-neutral: `input_tokens` is the count of *uncached*
  # input tokens, because both providers report a total that ruby_llm reduces
  # by `cached_tokens`. `tool_calls:` entries are
  # `{ id:, name:, arguments: <JSON string> }`.
  def chat_completion_body(content: "Hello, world!", model: "gpt-4o-mini", tool_calls: nil, usage: DEFAULT_USAGE)
    if RUBY_LLM_V2
      responses_body(content: content, model: model, tool_calls: tool_calls, usage: usage)
    else
      chat_completions_body(content: content, model: model, tool_calls: tool_calls, usage: usage)
    end
  end

  def stub_chat_completion(*bodies)
    bodies = [chat_completion_body] if bodies.empty?
    responses = bodies.map do |body|
      { status: 200, headers: { "Content-Type" => "application/json" }, body: body }
    end

    stub_request(:post, openai_chat_url).to_return(*responses)
  end

  def stub_chat_completion_failure
    stub_request(:post, openai_chat_url).to_return(status: 500, body: "Internal Server Error")
  end

  # `Chat#with_tool` became `Chat#with_tools` in ruby_llm 2.0. Both return the
  # receiver, so this works for `RubyLLM::Agent` too.
  def with_capture_content
    config = OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config
    original = config[:capture_content]
    config[:capture_content] = true
    yield
  ensure
    config[:capture_content] = original
  end

  def with_tool(chat, tool)
    RUBY_LLM_V2 ? chat.with_tools(tool) : chat.with_tool(tool)
  end

  private

  # The OpenAI Chat Completions envelope, parsed by
  # `ruby_llm/providers/openai/chat.rb#parse_completion_response` on 1.x.
  def chat_completions_body(content:, model:, tool_calls:, usage:)
    message = { role: "assistant", content: content }
    if tool_calls
      message[:tool_calls] = tool_calls.map do |call|
        {
          id: call[:id],
          type: "function",
          function: { name: call[:name], arguments: call[:arguments] }
        }
      end
    end

    {
      id: "chatcmpl-123",
      object: "chat.completion",
      model: model,
      choices: [{
        index: 0,
        message: message,
        finish_reason: tool_calls ? "tool_calls" : "stop"
      }],
      usage: chat_completions_usage(usage)
    }.to_json
  end

  def chat_completions_usage(usage)
    prompt_tokens = usage.fetch(:input_tokens) + usage[:cached_tokens].to_i
    completion_tokens = usage.fetch(:output_tokens)

    body = {
      prompt_tokens: prompt_tokens,
      completion_tokens: completion_tokens,
      total_tokens: prompt_tokens + completion_tokens
    }
    body[:prompt_tokens_details] = { cached_tokens: usage[:cached_tokens] } if usage[:cached_tokens]
    body
  end

  # The OpenAI Responses envelope, parsed by
  # `ruby_llm/protocols/responses/chat.rb` on 2.0: assistant text rides in an
  # `output` item of type "message" whose parts are "output_text"
  # (`parse_output_text`), tool calls are top-level "function_call" items
  # keyed by `call_id` (`parse_function_calls`), `status: "completed"` is what
  # `parse_finish_reason` maps to `:stop`, and `parse_usage` reads
  # `input_tokens`/`output_tokens` with cache reads under
  # `input_tokens_details.cached_tokens`.
  def responses_body(content:, model:, tool_calls:, usage:)
    output = []

    if content
      output << {
        id: "msg_123",
        type: "message",
        status: "completed",
        role: "assistant",
        content: [{ type: "output_text", text: content, annotations: [] }]
      }
    end

    Array(tool_calls).each do |call|
      output << {
        id: "fc_#{call[:id]}",
        type: "function_call",
        status: "completed",
        call_id: call[:id],
        name: call[:name],
        arguments: call[:arguments]
      }
    end

    {
      id: "resp_123",
      object: "response",
      status: "completed",
      model: model,
      output: output,
      usage: responses_usage(usage)
    }.to_json
  end

  def responses_usage(usage)
    input_tokens = usage.fetch(:input_tokens) + usage[:cached_tokens].to_i
    output_tokens = usage.fetch(:output_tokens)

    body = {
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: input_tokens + output_tokens
    }
    body[:input_tokens_details] = { cached_tokens: usage[:cached_tokens] } if usage[:cached_tokens]
    body
  end
end

EXPORTER = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
span_processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(EXPORTER)

OpenTelemetry::SDK.configure do |c|
  c.add_span_processor(span_processor)
  c.use "OpenTelemetry::Instrumentation::RubyLLM"
end
