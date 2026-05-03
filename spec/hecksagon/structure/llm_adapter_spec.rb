# spec/hecksagon/structure/llm_adapter_spec.rb
#
# Value-object contract for Hecksagon::Structure::LlmAdapter.
#
require_relative "../spec_helper"

RSpec.describe Hecksagon::Structure::LlmAdapter do
  let(:valid_attrs) do
    {
      name: :dream_image,
      prompt_template: "You are Miette dreaming. Seed: {{seed_image}}",
      model: "claude-sonnet-4",
      max_tokens: 200,
      response_into_target: "Dream.ProduceImage",
      response_into_attr: :text_fr,
      backend: :claude,
    }
  end

  describe "#initialize" do
    it "accepts a fully-specified adapter" do
      adapter = described_class.new(**valid_attrs)
      expect(adapter.name).to eq(:dream_image)
      expect(adapter.prompt_template).to include("{{seed_image}}")
      expect(adapter.model).to eq("claude-sonnet-4")
      expect(adapter.max_tokens).to eq(200)
      expect(adapter.response_into_target).to eq("Dream.ProduceImage")
      expect(adapter.response_into_attr).to eq(:text_fr)
      expect(adapter.backend).to eq(:claude)
    end

    it "defaults prompt_template to '' and other optionals to nil" do
      adapter = described_class.new(name: :bare)
      expect(adapter.prompt_template).to eq("")
      expect(adapter.model).to be_nil
      expect(adapter.max_tokens).to be_nil
      expect(adapter.response_into_target).to be_nil
      expect(adapter.response_into_attr).to be_nil
      expect(adapter.backend).to be_nil
    end

    it "rejects a nil name" do
      expect { described_class.new(name: nil) }
        .to raise_error(ArgumentError, /name/)
    end
  end

  describe "#placeholders" do
    it "returns unique placeholder names in first-appearance order" do
      adapter = described_class.new(
        name: :p,
        prompt_template: "Hello {{a}} and {{b}}, again {{a}}.",
      )
      expect(adapter.placeholders).to eq([:a, :b])
    end

    it "returns [] when the template has no placeholders" do
      adapter = described_class.new(name: :p, prompt_template: "static")
      expect(adapter.placeholders).to eq([])
    end
  end

  describe "#to_h" do
    it "returns a Hash with every declared field" do
      adapter = described_class.new(**valid_attrs)
      expect(adapter.to_h.keys).to include(
        :name, :prompt_template, :model, :max_tokens,
        :response_into_target, :response_into_attr, :backend
      )
    end
  end
end
