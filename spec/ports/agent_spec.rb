require "hecksagain"
require_relative "../fixtures/scripted_agent"

RSpec.describe Hecksagain::Ports::Agent do
  def registry_with(*adapter_paths)
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.expand_path("../../lib/hecksagain/ports/agent.port", __dir__))
      adapter_paths.each { |path| Kernel.load(path) }
    end
    registry
  end

  CLAUDE_CODE_ADAPTER = File.expand_path("../../lib/hecksagain/adapters/driven/claude_code.adapter", __dir__)
  SCRIPTED_ADAPTER     = File.expand_path("../fixtures/scripted_agent.adapter", __dir__)

  before { Hecksagain::Adapters::ScriptedAgent.reset! }

  describe "resolution" do
    it "refuses when no adapter implements the port" do
      registry = registry_with
      expect { described_class.ask(registry, state: {}) }
        .to raise_error(Hecksagain::Runtime::WiringError, /no adapter implements/)
    end

    it "resolves the one bound adapter" do
      registry = registry_with(SCRIPTED_ADAPTER)
      Hecksagain::Adapters::ScriptedAgent.script(:ask, { "questions" => [{ "text" => "what?", "because" => "why not" }] })

      questions = described_class.ask(registry, state: {})
      expect(questions.first.text).to eq("what?")
    end

    it "refuses to choose between more than one bound adapter" do
      registry = registry_with(CLAUDE_CODE_ADAPTER, SCRIPTED_ADAPTER)
      expect { described_class.ask(registry, state: {}) }
        .to raise_error(Hecksagain::Runtime::WiringError, /ClaudeCode, ScriptedAgent/)
    end
  end

  describe "the four operations, against the scripted double" do
    let(:registry) { registry_with(SCRIPTED_ADAPTER) }

    it "ask returns Question structs" do
      Hecksagain::Adapters::ScriptedAgent.script(
        :ask, { "questions" => [{ "text" => "what identifies a Loyalty Member?", "because" => "no identity yet" }] }
      )

      questions = described_class.ask(registry, state: { chapter: "Loyalty" }, asked: [])
      expect(questions).to eq([described_class::Question.new(text: "what identifies a Loyalty Member?",
                                                               because: "no identity yet")])
    end

    it "interpret returns Proposal structs shaped as Interview::Proposal Argument rows" do
      Hecksagain::Adapters::ScriptedAgent.script(
        :interpret,
        { "proposals" => [{ "verb" => "Loyalty::Member.Declare", "rationale" => "named a new aggregate",
                             "arguments" => [{ "name" => "name", "field" => "value", "value" => "Member" }] }] }
      )

      proposals = described_class.interpret(registry, prose: "a member has a loyalty tier", state: {})
      expect(proposals.size).to eq(1)
      expect(proposals.first.verb).to eq("Loyalty::Member.Declare")
      expect(proposals.first.arguments).to eq([{ name: "name", field: "value", value: "Member" }])
    end

    it "interpret tolerates a sentence with no declaration in it" do
      Hecksagain::Adapters::ScriptedAgent.script(:interpret, { "proposals" => [] })
      expect(described_class.interpret(registry, prose: "why do you ask?", state: {})).to eq([])
    end

    it "critique returns Finding structs, closed to the known kind and severity vocabularies" do
      Hecksagain::Adapters::ScriptedAgent.script(
        :critique,
        { "findings" => [{ "kind" => "crud_verb", "severity" => "warning", "subject" => "Loyalty::Member.Update",
                            "message" => "says nothing about what changed or why" }] }
      )

      findings = described_class.critique(registry, declared: {}, refusals: [], findings: [])
      expect(findings.first.kind).to eq(:crud_verb)
      expect(findings.first.severity).to eq(:warning)
    end

    it "critique refuses a kind outside the closed vocabulary" do
      Hecksagain::Adapters::ScriptedAgent.script(
        :critique,
        { "findings" => [{ "kind" => "bad_vibes", "severity" => "warning", "subject" => "x", "message" => "y" }] }
      )

      expect { described_class.critique(registry, declared: {}, refusals: [], findings: []) }
        .to raise_error(described_class::ValidationError, /not a critique kind/)
    end

    it "suggest_name returns Suggestion structs, rejected near-misses included" do
      Hecksagain::Adapters::ScriptedAgent.script(
        :name, { "names" => [{ "name" => "TierChanged", "because" => "past tense, the language's own convention",
                                "rejected" => ["TierChange", "ChangeTier"] }] }
      )

      suggestions = described_class.suggest_name(registry, meaning: "a member's tier moved", kind: "event", near: [])
      expect(suggestions.first.name).to eq("TierChanged")
      expect(suggestions.first.rejected).to eq(["TierChange", "ChangeTier"])
    end

    it "a malformed answer raises ValidationError rather than a bare Ruby error" do
      Hecksagain::Adapters::ScriptedAgent.script(:ask, { "questions" => [{ "because" => "no text at all" }] })
      expect { described_class.ask(registry, state: {}) }
        .to raise_error(described_class::ValidationError, /"text"/)
    end

    it "an exhausted queue raises Unavailable, not a silent nil" do
      expect { described_class.ask(registry, state: {}) }.to raise_error(described_class::Unavailable, /no ask answer queued/)
    end
  end
end
