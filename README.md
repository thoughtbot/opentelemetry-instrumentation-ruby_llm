# OpenTelemetry RubyLLM Instrumentation

OpenTelemetry instrumentation for [RubyLLM](https://rubyllm.com).

## How do I get started?

Install the gem using:

```sh
gem install opentelemetry-instrumentation-ruby_llm
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

### Tool result length

Tool call results are recorded on `execute_tool` spans via `gen_ai.tool.call.result`, truncated to 500 characters by default. Adjust the limit with `tool_result_max_length`:

```ruby
OpenTelemetry::SDK.configure do |c|
  c.use 'OpenTelemetry::Instrumentation::RubyLLM', tool_result_max_length: 1000
end
```

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

### Conversation and user tracking

To correlate multi-turn conversations, set `gen_ai.conversation.id` via `with_otel_attributes`
using a real conversation/session identifier from your application (e.g. a thread or chat
record id):

```ruby
chat.with_otel_attributes("gen_ai.conversation.id" => session.id)
```

The instrumentation does not generate one for you. Per the
[GenAI semantic conventions](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/gen-ai-spans.md),
when no conversation identifier is available, instrumentations should not populate the
attribute — a fabricated value such as a random UUID should not be used as a fallback.

You can attach user identity the same way, using the OpenTelemetry
[`user.*`](https://opentelemetry.io/docs/specs/semconv/registry/attributes/user/) registry
attributes (the GenAI conventions do not define a user attribute):

```ruby
chat.with_otel_attributes(
  "gen_ai.conversation.id" => session.id,
  "user.id" => current_user.id,
  "user.email" => current_user.email
)
```

### Agent tracing

On `ruby_llm` >= 1.12.1, invoking a `RubyLLM::Agent` subclass wraps the whole run —
including tool loops and their follow-up completions — in a single `invoke_agent` span:

```ruby
class ResearchAgent < RubyLLM::Agent
  model "gpt-4o-mini"
end

ResearchAgent.new.ask("Find recent papers on prompt caching")
```

This produces one trace rooted at `invoke_agent ResearchAgent`
(`gen_ai.operation.name` = `invoke_agent`, `gen_ai.agent.name` = `ResearchAgent`), with
the chat and tool spans nested beneath it.

When the agent's chat is a persisted `acts_as_chat` record, the span also carries
`gen_ai.conversation.id` set to the record's id, so multi-turn conversations correlate
across jobs and requests without any extra code.

With `capture_content` enabled, the `invoke_agent` span also records
`gen_ai.input.messages` (the conversation history going in) and
`gen_ai.output.messages` (the final response), so backends that read the trace root
— like Langfuse — show the run's input and output at the trace level.

Only agent *instances* are wrapped. Class-level entry points that return the chat
record itself (`ResearchAgent.find(id)`, `ResearchAgent.create!`) bypass the agent
span — wrap the record with `ResearchAgent.new(chat: record)` to get one.

`with_otel_attributes` works on agents too — attributes are set on the `invoke_agent`
span (the trace root) and forwarded to the underlying chat:

```ruby
agent = ResearchAgent.new(chat: chat_record)
agent.with_otel_attributes("user.id" => current_user.id)
agent.ask("...")
```

## What's traced?

| Feature | Status |
|---------|--------|
| Chat completions | Supported |
| Tool calls | Supported |
| Agent invocations (`invoke_agent` spans) | Supported (`ruby_llm` >= 1.12.1) |
| Error handling | Supported |
| Opt-in input/output content capture | Supported |
| Conversation tracking (`gen_ai.conversation.id`) | Supported (automatic for persisted agent chats, or set your own id via `with_otel_attributes`) |
| System instructions capture | Supported (via `capture_content`) |
| Custom attributes on traces and spans | Supported (via `with_otel_attributes`) |
| Embeddings | Supported |
| Streaming | Planned |

This gem follows the [OpenTelemetry GenAI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-spans/).

## Compatibility

This gem is tested against the following `ruby_llm` versions:

- `1.8.0` (minimum supported)
- `1.12.1` (agent tracing floor — `RubyLLM::Agent` shipped in 1.12.0, but only loads outside Rails from 1.12.1)
- `~> 1.8` (latest 1.x release)

The Ruby matrix covers Ruby 3.1, 3.2, 3.3, and 3.4.

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
