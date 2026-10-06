require "hecks"
require_relative "../fixtures/scripted_agent"

RSpec.describe Hecks::Ports::Agent do
  def registry_with(*adapter_paths)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.expand_path("../../lib/hecks/ports/agent.port", __dir__))
      adapter_paths.each { |path| Kernel.load(path) }
    end
    registry
  end

  CLAUDE_CODE_ADAPTER = File.expand_path("../../lib/hecks/adapters/driven/claude_code.adapter", __dir__)
  SCRIPTED_ADAPTER = File.expand_path("../fixtures/scripted_agent.adapter", __dir__)

  before { Hecks::Adapters::ScriptedAgent.reset! }

  describe "resolution" do
    it "refuses when no adapter implements the port" do
      registry = registry_with
      expect { described_class.ask(registry, state: {}) }
        .to raise_error(Hecks::Runtime::WiringError, /no adapter implements/)
    end

    it "resolves the one bound adapter" do
      registry = registry_with(SCRIPTED_ADAPTER)
      Hecks::Adapters::ScriptedAgent.script(:ask, { "questions" => [{ "text" => "what?", "because" => "why not" }] })

      expect(described_class.ask(registry, state: {}).first.text).to eq("what?")
    end

    it "refuses to choose between more than one bound adapter" do
      registry = registry_with(CLAUDE_CODE_ADAPTER, SCRIPTED_ADAPTER)
      expect { described_class.ask(registry, state: {}) }
        .to raise_error(Hecks::Runtime::WiringError, /ClaudeCode, ScriptedAgent/)
    end
  end

  describe "the four operations, against the scripted double" do
    let(:registry) { registry_with(SCRIPTED_ADAPTER) }

    def script(operation, answer)
      Hecks::Adapters::ScriptedAgent.script(operation, answer)
    end

    def critique
      described_class.critique(registry, declared: {}, refusals: [], findings: [])
    end

    def ask
      described_class.ask(registry, state: {})
    end

    def interpret
      described_class.interpret(registry, prose: "a member has a loyalty tier", state: {})
    end

    it "ask returns Question structs" do
      script(:ask, { "questions" => [{ "text" => "what identifies a Loyalty Member?", "because" => "no identity yet" }] })

      expect(described_class.ask(registry, state: { chapter: "Loyalty" }, asked: []))
        .to eq([described_class::Question.new(text: "what identifies a Loyalty Member?", because: "no identity yet")])
    end

    describe "interpret returns Proposal structs shaped as Interview::Proposal Argument rows" do
      before do
        script(:interpret,
               { "proposals" => [{ "verb" => "Loyalty::Member.Declare", "rationale" => "named a new aggregate",
                                    "arguments" => [{ "name" => "name", "field" => "value", "value" => "Member" }] }] })
      end

      it "answers one proposal" do
        expect(interpret.size).to eq(1)
      end

      it "names the verb" do
        expect(interpret.first.verb).to eq("Loyalty::Member.Declare")
      end

      it "carries the arguments as rows" do
        expect(interpret.first.arguments).to eq([{ name: "name", field: "value", value: "Member" }])
      end
    end

    it "interpret tolerates a sentence with no declaration in it" do
      script(:interpret, { "proposals" => [] })
      expect(described_class.interpret(registry, prose: "why do you ask?", state: {})).to eq([])
    end

    describe "critique returns Finding structs, closed to the known kind and severity vocabularies" do
      before do
        script(:critique,
               { "findings" => [{ "kind" => "crud_verb", "severity" => "warning", "subject" => "Loyalty::Member.Update",
                                   "message" => "says nothing about what changed or why" }] })
      end

      it "closes the kind" do
        expect(critique.first.kind).to eq(:crud_verb)
      end

      it "closes the severity" do
        expect(critique.first.severity).to eq(:warning)
      end
    end

    it "critique refuses a kind outside the closed vocabulary" do
      script(:critique, { "findings" => [{ "kind" => "bad_vibes", "severity" => "warning", "subject" => "x",
                                           "message" => "y" }] })

      expect { critique }.to raise_error(described_class::ValidationError, /not a critique kind/)
    end

    describe "suggest_name returns Suggestion structs, rejected near-misses included" do
      let(:suggestions) do
        described_class.suggest_name(registry, meaning: "a member's tier moved", kind: "event", near: [])
      end

      before do
        script(:name, { "names" => [{ "name" => "TierChanged", "because" => "past tense, the language's own convention",
                                       "rejected" => ["TierChange", "ChangeTier"] }] })
      end

      it "names the suggestion" do
        expect(suggestions.first.name).to eq("TierChanged")
      end

      it "keeps the rejected near-misses" do
        expect(suggestions.first.rejected).to eq(["TierChange", "ChangeTier"])
      end
    end

    it "a malformed answer raises ValidationError rather than a bare Ruby error" do
      script(:ask, { "questions" => [{ "because" => "no text at all" }] })
      expect { ask }.to raise_error(described_class::ValidationError, /"text"/)
    end

    it "an exhausted queue raises Unavailable, not a silent nil" do
      expect { ask }.to raise_error(described_class::Unavailable, /no ask answer queued/)
    end
  end
end
