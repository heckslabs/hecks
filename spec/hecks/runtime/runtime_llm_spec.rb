# spec/hecks/runtime/runtime_llm_spec.rb
#
# Contract for Runtime#register_llm_adapter and Runtime#llm.
# Mirrors spec/hecks/runtime/runtime_shell_spec.rb in shape — they
# are siblings and the surfaces are intentionally parallel.
#
# Note : the LlmDispatcher this spec exercises is the step-8 stub.
# Steps 4 (PR #561) and 6 (PR #564) replace it with a real provider-
# routing implementation. Once one of those merges, the
# "dispatches through LlmDispatcher" expectation here will need to
# be updated to assert against a real Result rather than the stub's
# NotImplementedError.
#
$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "hecks"

RSpec.describe Hecks::Runtime do
  before do
    @domain = Hecks.bluebook("LlmRt") do
      aggregate "Widget" do
        attribute :id, String
      end
    end
    Hecks.load_bluebook(@domain, skip_validation: true)
  end

  let(:runtime) { described_class.new(@domain) }

  let(:dream_adapter) do
    Hecksagon::Structure::LlmAdapter.new(
      name: :dream_image,
      prompt_template: "Imagine {{seed_image}}",
      model: "claude-sonnet-4",
      max_tokens: 100,
      response_into_target: "Dream.ProduceImage",
      response_into_attr: :text_fr,
      backend: :fixture
    )
  end

  describe "#register_llm_adapter" do
    it "stores the adapter by name" do
      runtime.register_llm_adapter(dream_adapter)
      # Look-up confirmed by #llm reaching the dispatcher. Post-step-4
      # the dispatcher is real ; we just need to confirm the lookup
      # delegates rather than raising ConfigurationError.
      expect(Hecks::Runtime::LlmDispatcher).to receive(:call).and_return(:ok)
      expect { runtime.llm(:dream_image, seed_image: "blue") }.not_to raise_error
    end
  end

  describe "#llm" do
    it "raises ConfigurationError for an unknown adapter" do
      expect { runtime.llm(:missing) }
        .to raise_error(Hecks::ConfigurationError, /no llm adapter/)
    end

    it "dispatches through LlmDispatcher when the adapter is registered" do
      runtime.register_llm_adapter(dream_adapter)
      expect(Hecks::Runtime::LlmDispatcher)
        .to receive(:call)
        .with(dream_adapter, hash_including(seed_image: "blue"))
        .and_return(:dispatched)
      expect(runtime.llm(:dream_image, seed_image: "blue")).to eq(:dispatched)
    end

    it "accepts string names" do
      runtime.register_llm_adapter(dream_adapter)
      expect(Hecks::Runtime::LlmDispatcher)
        .to receive(:call)
        .with(dream_adapter, hash_including(seed_image: "x"))
        .and_return(:ok)
      expect(runtime.llm("dream_image", seed_image: "x")).to eq(:ok)
    end

    it "names the runtime's domain in the ConfigurationError" do
      expect { runtime.llm(:nope) }
        .to raise_error(Hecks::ConfigurationError, /:LlmRt/)
    end
  end
end
