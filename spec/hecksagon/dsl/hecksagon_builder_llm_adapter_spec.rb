# spec/hecksagon/dsl/hecksagon_builder_llm_adapter_spec.rb
#
# Contract for HecksagonBuilder#adapter dispatching on :llm.
#
require_relative "../spec_helper"

RSpec.describe Hecksagon::DSL::HecksagonBuilder do
  describe "#adapter :llm" do
    it "appends an llm adapter built from a block" do
      builder = described_class.new("App")
      builder.adapter :llm, name: :dream_image do
        prompt_template "Seed: {{seed_image}}"
        model "claude-sonnet-4"
        max_tokens 200
        response_into "Dream.ProduceImage", attr: :text_fr
        backend :claude
      end
      hex = builder.build
      expect(hex.llm_adapters.size).to eq(1)
      adapter = hex.llm_adapter(:dream_image)
      expect(adapter).to be_a(Hecksagon::Structure::LlmAdapter)
      expect(adapter.prompt_template).to include("{{seed_image}}")
      expect(adapter.model).to eq("claude-sonnet-4")
      expect(adapter.max_tokens).to eq(200)
      expect(adapter.response_into_target).to eq("Dream.ProduceImage")
      expect(adapter.response_into_attr).to eq(:text_fr)
      expect(adapter.backend).to eq(:claude)
    end

    it "appends from the one-liner keyword form" do
      builder = described_class.new("App")
      builder.adapter :llm, name: :quick,
                            prompt_template: "Hi",
                            model: "claude-sonnet-4",
                            max_tokens: 10,
                            backend: :claude
      hex = builder.build
      adapter = hex.llm_adapter(:quick)
      expect(adapter.prompt_template).to eq("Hi")
      expect(adapter.max_tokens).to eq(10)
    end

    it "falls back to io_adapter bucket when name: is omitted (backward-compat)" do
      builder = described_class.new("App")
      builder.adapter :llm, backend: :claude
      hex = builder.build
      expect(hex.llm_adapters).to be_empty
      io = hex.io_adapters.find { |a| a.kind == :llm }
      expect(io).not_to be_nil
      expect(io.options).to include(backend: :claude)
    end

    it "raises on duplicate adapter names within the same hecksagon" do
      builder = described_class.new("App")
      builder.adapter :llm, name: :dup, prompt_template: "x"
      expect {
        builder.adapter :llm, name: :dup, prompt_template: "y"
      }.to raise_error(ArgumentError, /already declared/)
    end

    it "allows multiple distinct llm adapters" do
      builder = described_class.new("App")
      builder.adapter :llm, name: :a, prompt_template: "a"
      builder.adapter :llm, name: :b, prompt_template: "b"
      hex = builder.build
      expect(hex.llm_adapters.map(&:name)).to eq([:a, :b])
    end
  end
end
