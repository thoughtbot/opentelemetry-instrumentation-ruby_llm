require "test_helper"

if defined?(RubyLLM::Agent)
  class ResearchAgent < RubyLLM::Agent
    model "gpt-4o-mini"
  end

  class AgentInstrumentationTest < Minitest::Test
    include ChatCompletionStubs

    def setup
      EXPORTER.reset

      RubyLLM.configure do |c|
        c.openai_api_key = "fake-key-for-testing"
      end
    end

    def test_wraps_ask_in_invoke_agent_span_with_chat_span_as_child
      stub_chat_completion

      agent = ResearchAgent.new
      agent.ask("Hi")

      spans = EXPORTER.finished_spans
      agent_span = spans.find { |s| s.name.start_with?("invoke_agent") }
      chat_span = spans.find { |s| s.name.start_with?("chat ") }

      assert_equal "invoke_agent ResearchAgent", agent_span.name
      assert_equal OpenTelemetry::Trace::SpanKind::INTERNAL, agent_span.kind
      assert_equal "invoke_agent", agent_span.attributes["gen_ai.operation.name"]
      assert_equal "ResearchAgent", agent_span.attributes["gen_ai.agent.name"]
      assert_equal agent_span.span_id, chat_span.parent_span_id
      assert_equal agent_span.trace_id, chat_span.trace_id
    end

    def test_wraps_complete_called_directly_in_invoke_agent_span
      stub_chat_completion

      agent = ResearchAgent.new
      agent.add_message(role: :user, content: "Hi")
      agent.complete

      spans = EXPORTER.finished_spans
      agent_span = spans.find { |s| s.name.start_with?("invoke_agent") }
      chat_span = spans.find { |s| s.name.start_with?("chat ") }

      assert_equal "invoke_agent ResearchAgent", agent_span.name
      assert_equal agent_span.span_id, chat_span.parent_span_id
    end

    def test_omits_agent_name_for_anonymous_agent_classes
      stub_chat_completion

      agent_class = Class.new(RubyLLM::Agent) do
        model "gpt-4o-mini"
      end

      agent_class.new.ask("Hi")

      agent_span = EXPORTER.finished_spans.find { |s| s.name.start_with?("invoke_agent") }

      assert_equal "invoke_agent", agent_span.name
      assert_nil agent_span.attributes["gen_ai.agent.name"]
    end

    def test_sets_conversation_id_stamped_on_the_chat
      stub_chat_completion

      chat = RubyLLM.chat(model: "gpt-4o-mini")
      chat.otel_conversation_id = "42"

      agent = ResearchAgent.new(chat: chat)
      agent.ask("Hi")

      agent_span = EXPORTER.finished_spans.find { |s| s.name.start_with?("invoke_agent") }
      assert_equal "42", agent_span.attributes["gen_ai.conversation.id"]
    end

    def test_omits_conversation_id_for_unpersisted_chats
      stub_chat_completion

      ResearchAgent.new.ask("Hi")

      agent_span = EXPORTER.finished_spans.find { |s| s.name.start_with?("invoke_agent") }
      assert_nil agent_span.attributes["gen_ai.conversation.id"]
    end

    def test_records_error_on_agent_span_when_ask_fails
      stub_request(:post, "https://api.openai.com/v1/chat/completions")
        .to_return(status: 500, body: "Internal Server Error")

      agent = ResearchAgent.new

      assert_raises do
        agent.ask("Hi")
      end

      agent_span = EXPORTER.finished_spans.find { |s| s.name.start_with?("invoke_agent") }
      assert agent_span.attributes["error.type"]
      assert_equal OpenTelemetry::Trace::Status::ERROR, agent_span.status.code

      exception_events = agent_span.events.select { |e| e.name == "exception" }
      assert_equal 1, exception_events.length
    end

    def test_sets_otel_attributes_on_agent_span_when_ask_fails
      stub_request(:post, "https://api.openai.com/v1/chat/completions")
        .to_return(status: 500, body: "Internal Server Error")

      agent = ResearchAgent.new
      agent.with_otel_attributes("langfuse.session.id" => "session-1")

      assert_raises do
        agent.ask("Hi")
      end

      agent_span = EXPORTER.finished_spans.find { |s| s.name.start_with?("invoke_agent") }
      assert_equal "session-1", agent_span.attributes["langfuse.session.id"]
    end

    def test_with_otel_attributes_sets_attributes_on_agent_and_chat_spans
      stub_chat_completion

      agent = ResearchAgent.new
      result = agent.with_otel_attributes("langfuse.session.id" => "session-1")
      agent.ask("Hi")

      assert_same agent, result

      spans = EXPORTER.finished_spans
      agent_span = spans.find { |s| s.name.start_with?("invoke_agent") }
      chat_span = spans.find { |s| s.name.start_with?("chat ") }

      assert_equal "session-1", agent_span.attributes["langfuse.session.id"]
      assert_equal "session-1", chat_span.attributes["langfuse.session.id"]
    end

    def test_with_otel_attributes_forwards_through_to_llm_for_chat_records
      stub_chat_completion

      llm_chat = RubyLLM.chat(model: "gpt-4o-mini")
      llm_chat.otel_conversation_id = "7"
      record = Object.new
      record.define_singleton_method(:to_llm) { llm_chat }
      record.define_singleton_method(:ask) { |message| llm_chat.ask(message) }

      agent = ResearchAgent.new(chat: record)
      agent.with_otel_attributes("user.id" => "u1")
      agent.ask("Hi")

      spans = EXPORTER.finished_spans
      agent_span = spans.find { |s| s.name.start_with?("invoke_agent") }
      chat_span = spans.find { |s| s.name.start_with?("chat ") }

      assert_equal "7", agent_span.attributes["gen_ai.conversation.id"]
      assert_equal "u1", agent_span.attributes["user.id"]
      assert_equal "u1", chat_span.attributes["user.id"]
    end

    def test_wraps_say_in_invoke_agent_span
      stub_chat_completion

      ResearchAgent.new.say("Hi")

      agent_span = EXPORTER.finished_spans.find { |s| s.name.start_with?("invoke_agent") }
      assert_equal "invoke_agent ResearchAgent", agent_span.name
    end

    def test_creates_one_agent_span_for_ask_with_tool_loop
      calculator = Class.new(RubyLLM::Tool) do
        def self.name = "calculator"
        description "Performs math"
        param :expression, type: "string", desc: "Math expression"

        def execute(expression:)
          eval(expression).to_s
        end
      end

      stub_chat_completion(
        chat_completion_body(
          content: nil,
          tool_calls: [{
            id: "call_abc123",
            type: "function",
            function: { name: "calculator", arguments: '{"expression":"2+2"}' }
          }]
        ),
        chat_completion_body(
          content: "The answer is 4",
          usage: { prompt_tokens: 20, completion_tokens: 5, total_tokens: 25 }
        )
      )

      agent = ResearchAgent.new
      agent.with_tool(calculator)
      agent.ask("What is 2+2?")

      spans = EXPORTER.finished_spans
      agent_spans = spans.select { |s| s.name.start_with?("invoke_agent") }
      chat_spans = spans.select { |s| s.name.start_with?("chat ") }
      tool_spans = spans.select { |s| s.name.start_with?("execute_tool ") }

      assert_equal 1, agent_spans.length
      assert_equal 2, chat_spans.length
      assert_equal 1, tool_spans.length

      agent_span = agent_spans.first
      assert(chat_spans.all? { |s| s.trace_id == agent_span.trace_id })
      assert_equal agent_span.trace_id, tool_spans.first.trace_id
    end

    def test_captures_input_and_output_on_agent_span_when_enabled
      OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:capture_content] = true
      stub_chat_completion

      ResearchAgent.new.ask("Hi")

      agent_span = EXPORTER.finished_spans.find { |s| s.name.start_with?("invoke_agent") }

      input_messages = JSON.parse(agent_span.attributes["gen_ai.input.messages"])
      assert_equal 1, input_messages.length
      assert_equal "user", input_messages[0]["role"]
      assert_equal [{ "type" => "text", "content" => "Hi" }], input_messages[0]["parts"]

      output_messages = JSON.parse(agent_span.attributes["gen_ai.output.messages"])
      assert_equal 1, output_messages.length
      assert_equal "assistant", output_messages[0]["role"]
      assert_equal [{ "type" => "text", "content" => "Hello, world!" }], output_messages[0]["parts"]
    ensure
      OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:capture_content] = false
    end

    def test_does_not_capture_content_on_agent_span_by_default
      stub_chat_completion

      ResearchAgent.new.ask("Hi")

      agent_span = EXPORTER.finished_spans.find { |s| s.name.start_with?("invoke_agent") }
      assert_nil agent_span.attributes["gen_ai.input.messages"]
      assert_nil agent_span.attributes["gen_ai.output.messages"]
    end
  end
end
