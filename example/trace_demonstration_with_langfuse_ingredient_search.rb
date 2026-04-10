# frozen_string_literal: true

require "bundler/inline"

gemfile(true) do
  source "https://rubygems.org"
  gem "ruby_llm"
  gem "opentelemetry-api"
  gem "opentelemetry-sdk"
  gem "opentelemetry-exporter-otlp"
  gem "opentelemetry-instrumentation-ruby_llm", path: "../"
  gem "base64"
  gem "dotenv"
end

require "base64"
require "dotenv/load"

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

INGREDIENT_DATABASE = {
  "vitamin d3" => {
    name: "Vitamin D3 (Cholecalciferol)",
    common_doses: "1,000-5,000 IU daily",
    side_effects: ["Nausea", "Vomiting", "Constipation", "Loss of appetite", "Excessive thirst", "Frequent urination", "Kidney stones (at very high doses)"],
    interactions: ["Corticosteroids", "Orlistat", "Statins", "Thiazide diuretics"],
    notes: "Fat-soluble vitamin. Toxicity risk at sustained doses above 10,000 IU/day."
  },
  "magnesium glycinate" => {
    name: "Magnesium Glycinate",
    common_doses: "200-400 mg daily",
    side_effects: ["Diarrhea", "Nausea", "Abdominal cramping"],
    interactions: ["Antibiotics (tetracyclines, quinolones)", "Bisphosphonates", "Diuretics"],
    notes: "Better absorbed and gentler on the stomach than magnesium oxide."
  },
  "zinc" => {
    name: "Zinc",
    common_doses: "15-30 mg daily",
    side_effects: ["Nausea", "Metallic taste", "Headache", "Copper deficiency (long-term use)"],
    interactions: ["Antibiotics", "Penicillamine", "Copper supplements"],
    notes: "Best taken with food to reduce nausea. Long-term use above 40 mg/day may deplete copper."
  }
}

class SearchForIngredientDetails < RubyLLM::Tool
  description "Searches a database for detailed information about a supplement ingredient, including side effects, interactions, and dosage"
  param :ingredient_name, type: "string", desc: "The name of the ingredient to search for (e.g., 'vitamin d3', 'magnesium glycinate')"

  def execute(ingredient_name:)
    key = ingredient_name.downcase.strip
    match = INGREDIENT_DATABASE.find { |k, _| key.include?(k) || k.include?(key) }

    if match
      _, details = match
      details.map { |k, v| "#{k}: #{Array(v).join(', ')}" }.join("\n")
    else
      "No information found for '#{ingredient_name}'. Available ingredients: #{INGREDIENT_DATABASE.keys.join(', ')}"
    end
  end
end

chat = RubyLLM.chat
chat.with_instructions("You are a knowledgeable health supplement assistant. Use the search tool to look up ingredient details before answering questions.")
chat.with_tool(SearchForIngredientDetails)

questions = [
  { text: "What are the side effects of Vitamin D3?", ingredient: "vitamin d3" },
  { text: "What are the common interactions with magnesium glycinate?", ingredient: "magnesium glycinate" },
  { text: "What is the recommended dosage for zinc?", ingredient: "zinc" },
  { text: "Are there any interactions I should be aware of with zinc?", ingredient: "zinc" }
]

questions.each do |q|
  puts "\n---\n\n"
  puts "Question: #{q[:text]}\n\n"

  chat.with_otel_attributes(
    "langfuse.observation.prompt.name" => "supplement-assistant",
    "langfuse.observation.prompt.version" => 1,
    "langfuse.observation.input" => q[:text],
    "langfuse.observation.output" => -> { chat.messages.last&.content.to_s },
    "langfuse.observation.metadata" => { ingredient: q[:ingredient] }.to_json,
    "langfuse.trace.metadata" => { ingredient: q[:ingredient] }.to_json,
    "langfuse.trace.tags" => [q[:ingredient]]
  )

  response = chat.ask(q[:text])
  puts "\nResponse: #{response.content}"
end

# This line is only necessary in short-lived scripts. In a long-running application, spans will be flushed automatically.
OpenTelemetry.tracer_provider.force_flush
