# OpenTelemetry RubyLLM Instrumentation

OpenTelemetry instrumentation for [RubyLLM](https://rubyllm.com).

## How do I get started?

Install the gem using:

```sh
gem opentelemetry-instrumentation-ruby_llm
```

Or, if you use [bundler](https://bundler.io/), include `opentelemetry-instrumentation-ruby_llm` in your `Gemfile`.

## Usage

To use the instrumentation, call `use` with the name of the instrumentation:

```ruby
OpenTelemetry::SDK.configure do |c|
  c.use 'OpenTelemetry::Instrumentation::RubyLLM'
end
```

Alternatively, you can also call `use_all` to install all the available instrumentation.

```ruby
OpenTelemetry::SDK.configure do |c|
  c.use_all
end
```

## Configuration

### Content capture

By default, message content is **not captured**. To enable it:

```ruby
OpenTelemetry::SDK.configure do |c|
  c.use 'OpenTelemetry::Instrumentation::RubyLLM', capture_content: true
end
```

Or set the environment variable:

```bash
export OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true
```

When enabled, the following attributes are added to chat spans:

| Attribute | Description |
|-----------|-------------|
| `gen_ai.system_instructions` | System instructions provided via `with_instructions` |
| `gen_ai.input.messages` | Input messages sent to the model |
| `gen_ai.output.messages` | Final output messages from the model |

> [!WARNING]
> Captured content may include sensitive or personally identifiable information (PII). Use with caution in production environments.

### Custom attributes

Use `with_otel_attributes` to add arbitrary attributes to the span for each request. This is useful for adding per-request metadata like Langfuse prompt linking or trace-level tags:

```ruby
chat = RubyLLM.chat
chat.with_otel_attributes(
  "langfuse.observation.prompt.name" => "supplement-assistant",
  "langfuse.observation.prompt.version" => 1,
  "langfuse.trace.tags" => ["vitamins"],
  "langfuse.trace.metadata" => { category: "health" }.to_json
)
chat.ask("What are the side effects of Vitamin D3?")
```

Values can also be callables (Procs/lambdas) that are evaluated after each completion, giving access to response data:

```ruby
chat.with_otel_attributes(
  "langfuse.observation.prompt.name" => "supplement-assistant",
  "langfuse.observation.output" => -> { chat.messages.last&.content.to_s }
)
```

Attributes persist across calls on the same chat instance and the method returns `self` for chaining.

## What's traced?

| Feature | Status |
|---------|--------|
| Chat completions | Supported |
| Tool calls | Supported |
| Error handling | Supported |
| Opt-in input/output content capture | Supported |
| Conversation tracking (`gen_ai.conversation.id`) | Planned |
| System instructions capture | Supported (via `capture_content`) |
| Custom attributes on traces and spans | Supported (via `with_otel_attributes`) |
| Embeddings | Planned |
| Streaming | Planned |

This gem follows the [OpenTelemetry GenAI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-spans/).

## License

Copyright (c) Clarissa Borges and thoughtbot, inc.

This gem is free software and may be redistributed under the terms specified in the [LICENSE](LICENSE) file.

<!-- START /templates/footer.md -->
## About thoughtbot

![thoughtbot](https://thoughtbot.com/thoughtbot-logo-for-readmes.svg)

This repo is maintained and funded by thoughtbot, inc.
The names and logos for thoughtbot are trademarks of thoughtbot, inc.

We love open source software!
See [our other projects][community].
We are [available for hire][hire].

[community]: https://thoughtbot.com/community?utm_source=github
[hire]: https://thoughtbot.com/hire-us?utm_source=github

<!-- END /templates/footer.md -->
