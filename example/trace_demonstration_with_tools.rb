# frozen_string_literal: true

require "bundler/inline"

gemfile(true) do
  source "https://rubygems.org"
  gem "ruby_llm"
  gem "opentelemetry-api"
  gem "opentelemetry-sdk"
  gem "opentelemetry-instrumentation-ruby_llm", path: "../"
end

ENV["OTEL_TRACES_EXPORTER"] ||= "console"

OpenTelemetry::SDK.configure do |c|
  c.use "OpenTelemetry::Instrumentation::RubyLLM"
end

RubyLLM.configure do |c|
  c.openai_api_key = ENV["OPENAI_API_KEY"]
  c.default_model = "gpt-5-nano"
end

class Calculator < RubyLLM::Tool
  description "Performs basic math calculations"
  param :expression, type: "string", desc: "Math expression to evaluate"

  def execute(expression:)
    eval(expression).to_s
  end
end

chat = RubyLLM.chat
chat.with_tool(Calculator)
response = chat.ask("What is 123 * 456?")
puts "\nResponse: #{response.content}"

# This line is only necessary in short-lived scripts. In a long-running application, spans will be flushed automatically.
OpenTelemetry.tracer_provider.force_flush
