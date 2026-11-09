# frozen_string_literal: true

require "bundler/inline"

gemfile(true) do
  source "https://rubygems.org"
  # The instrumentation supports ruby_llm 1.x and 2.x; these demos are pinned
  # to the current major so the API they call matches what bundler installs.
  gem "ruby_llm", "~> 2.0"
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

chat = RubyLLM.chat
response = chat.ask("What is the meaning of life?")
puts "\nResponse: #{response.content}"

# This line is only necessary in short-lived scripts. In a long-running application, spans will be flushed automatically.
OpenTelemetry.tracer_provider.force_flush
