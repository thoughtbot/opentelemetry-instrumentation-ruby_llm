$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "webmock/minitest"
require "ruby_llm"
require "opentelemetry/sdk"
require "opentelemetry-instrumentation-ruby_llm"

EXPORTER = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
span_processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(EXPORTER)

OpenTelemetry::SDK.configure do |c|
  c.add_span_processor(span_processor)
  c.use "OpenTelemetry::Instrumentation::RubyLLM"
end
