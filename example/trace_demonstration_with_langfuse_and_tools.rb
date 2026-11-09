# frozen_string_literal: true

require "bundler/inline"

gemfile(true) do
  source "https://rubygems.org"
  # The instrumentation supports ruby_llm 1.x and 2.x; these demos are written
  # against the current major, which renamed `Tool.param` to `Tool.parameter`
  # and `Chat#with_tool` to `Chat#with_tools`.
  gem "ruby_llm", "~> 2.0"
  gem "opentelemetry-api"
  gem "opentelemetry-sdk"
  gem "opentelemetry-exporter-otlp"
  gem "opentelemetry-instrumentation-ruby_llm", path: "../"
  gem "base64"
end

require "base64"

credentials = Base64.strict_encode64("#{ENV['LANGFUSE_PUBLIC_KEY']}:#{ENV['LANGFUSE_SECRET_KEY']}")

OpenTelemetry::SDK.configure do |c|
  c.service_name = "ruby_llm-demo"
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      OpenTelemetry::Exporter::OTLP::Exporter.new(
        endpoint: "https://us.cloud.langfuse.com/api/public/otel/v1/traces",
        headers: { "Authorization" => "Basic #{credentials}" }
      )
    )
  )
  c.use "OpenTelemetry::Instrumentation::RubyLLM", capture_content: true
end

RubyLLM.configure do |c|
  c.openai_api_key = ENV["OPENAI_API_KEY"]
  c.default_model = "gpt-5-nano"
end

class Calculator < RubyLLM::Tool
  description "Performs basic math calculations"
  parameter :expression, type: "string", description: "Math expression to evaluate"

  def execute(expression:)
    eval(expression).to_s
  end
end

chat = RubyLLM.chat
chat.with_instructions("You are a helpful assistant that provides concise answers.")
chat.with_tools(Calculator)
chat.with_otel_attributes(
  "langfuse.observation.prompt.name" => "helpful-assistant",
  "langfuse.observation.prompt.version" => 1
)
response = chat.ask("Use the calculator tool to compute 123 * 456")
puts "\nResponse: #{response.content}"
response = chat.ask("Use the tool again to compute 789 + 1011")
puts "\nResponse: #{response.content}"

# This line is only necessary in short-lived scripts. In a long-running application, spans will be flushed automatically.
OpenTelemetry.tracer_provider.force_flush
