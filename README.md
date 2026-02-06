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

## What's traced?

| Feature | Status |
|---------|--------|
| Chat completions | Supported |
| Tool calls | Supported |
| Error handling | Supported |
| Conversation tracking (`gen_ai.conversation.id`) | Planned |
| Opt-in input/output content capture | Planned |
| System instructions capture | Planned |
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
