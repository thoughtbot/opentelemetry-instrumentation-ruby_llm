require_relative "lib/opentelemetry/instrumentation/ruby_llm/version"

Gem::Specification.new do |spec|
  spec.name          = "opentelemetry-instrumentation-ruby_llm"
  spec.version       = OpenTelemetry::Instrumentation::RubyLLM::VERSION
  spec.authors       = ["Clarissa Borges"]
  spec.email         = ["cborges@thoughtbot.com"]
  spec.license       = "MIT"

  spec.summary     = "OpenTelemetry instrumentation for RubyLLM"
  spec.description = "Adds OpenTelemetry tracing to RubyLLM chat operations"
  spec.homepage    = "https://github.com/thoughtbot/opentelemetry-instrumentation-ruby_llm"

  spec.required_ruby_version = ">= 3.1.3"

  spec.metadata["homepage_uri"] = spec.homepage

  spec.files = `git ls-files`.split("\n")
  spec.require_paths = ["lib"]

  spec.add_dependency "opentelemetry-api", "~> 1.0"
  spec.add_dependency "opentelemetry-instrumentation-base", "~> 0.23"
end
