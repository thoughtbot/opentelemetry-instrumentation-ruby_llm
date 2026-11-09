# frozen_string_literal: true

# The instrumentation supports both `ruby_llm` majors, so each line is tested
# at its floor and at its tip. 1.8.0 is the overall floor because the
# embedding patch calls `RubyLLM::Models.resolve` (class-method delegation
# added in 1.8.0); 1.12.1 is the floor for agent tracing.

appraise "ruby_llm-1.8.0" do
  gem "ruby_llm", "1.8.0"
end

appraise "ruby_llm-1.12.1" do
  gem "ruby_llm", "1.12.1"
end

appraise "ruby_llm-1-latest" do
  gem "ruby_llm", "~> 1.8"
end

appraise "ruby_llm-2.0.0" do
  gem "ruby_llm", "2.0.0"
end

appraise "ruby_llm-2-latest" do
  gem "ruby_llm", "~> 2.0"
end
