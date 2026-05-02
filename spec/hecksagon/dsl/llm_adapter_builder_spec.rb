# spec/hecksagon/dsl/llm_adapter_builder_spec.rb
#
# Contract for Hecksagon::DSL::LlmAdapterBuilder.
#
require_relative "../spec_helper"

RSpec.describe Hecksagon::DSL::LlmAdapterBuilder do
  describe "#build" do
    it "builds an LlmAdapter from DSL block setters" do
      builder = described_class.new(:dream_image)
      builder.prompt_template "You are Miette dreaming. Seed: {{seed_image}}"
      builder.model "claude-sonnet-4"
      builder.max_tokens 200
      builder.response_into "Dream.ProduceImage", attr: :text_fr
      builder.backend :claude

      adapter = builder.build
      expect(adapter).to be_a(Hecksagon::Structure::LlmAdapter)
      expect(adapter.name).to eq(:dream_image)
      expect(adapter.prompt_template).to include("{{seed_image}}")
      expect(adapter.model).to eq("claude-sonnet-4")
      expect(adapter.max_tokens).to eq(200)
      expect(adapter.response_into_target).to eq("Dream.ProduceImage")
      expect(adapter.response_into_attr).to eq(:text_fr)
      expect(adapter.backend).to eq(:claude)
    end

    it "defaults prompt_template to '' when never declared" do
      builder = described_class.new(:bare)
      adapter = builder.build
      expect(adapter.prompt_template).to eq("")
      expect(adapter.model).to be_nil
      expect(adapter.max_tokens).to be_nil
    end
  end

  describe "#apply_options" do
    it "applies keyword-argument shortcuts from the one-liner form" do
      builder = described_class.new(:k)
      builder.apply_options(
        prompt_template: "Hi {{a}}",
        model: "claude-sonnet-4",
        max_tokens: 50,
        backend: :claude,
        response_into: "X.Y",
        response_attr: :text,
      )
      adapter = builder.build
      expect(adapter.prompt_template).to eq("Hi {{a}}")
      expect(adapter.model).to eq("claude-sonnet-4")
      expect(adapter.max_tokens).to eq(50)
      expect(adapter.backend).to eq(:claude)
      expect(adapter.response_into_target).to eq("X.Y")
      expect(adapter.response_into_attr).to eq(:text)
    end

    it "block setters and apply_options coexist" do
      builder = described_class.new(:mix)
      builder.model "from-block"
      builder.apply_options(max_tokens: 100)
      adapter = builder.build
      expect(adapter.model).to eq("from-block")
      expect(adapter.max_tokens).to eq(100)
    end
  end
end
