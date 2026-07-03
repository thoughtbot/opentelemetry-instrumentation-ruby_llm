# frozen_string_literal: true

# Test the instrumentation against the earliest supported `ruby_llm` and
# the latest 1.x release. 1.8.0 is the practical floor because the embedding
# patch calls `RubyLLM::Models.resolve` (class method delegation added in
# 1.8.0).

appraise "ruby_llm-1.8.0" do
  gem "ruby_llm", "1.8.0"
end

appraise "ruby_llm-1.12.1" do
  gem "ruby_llm", "1.12.1"
end

appraise "ruby_llm-1-latest" do
  gem "ruby_llm", "~> 1.8"
end
