require "spec_helper"
require "rack/mock"
require "tmpdir"
require "hecks/composer/web"
require "hecks/composer/adapters/fake_agent"
require "hecks/composer/adapters/jev"

# The Composer's agent is a driven adapter behind the `composer_agent` port. These specs run the
# whole flow against the scripted adapter: no model, no network, the workspace on disk edited the
# way the real agent would leave it.
RSpec.describe "the Composer's agent" do
  let(:workspace) { Dir.mktmpdir("composer-agent").tap { |dir| FileUtils.cp_r(Dir.glob("#{fixture}/*"), dir) } }
  let(:agents)    { agents_for("fake_agent") }

  REFUND = <<~RUBY.gsub(/^(?=.)/, "    ").freeze
    command "Refund", from: "open" do
      goal "Give money back"

      reference_to Account
      attribute :amount, PositiveMoney

      sets :balance, decrement: :amount

      emits AccountRefunded
    end

  RUBY

  before do
    Hecks::Composer::Parse.binary
    fake.reset!
  rescue Hecks::Composer::Parse::ParserMissing => e
    skip e.message
  end

  after { FileUtils.rm_rf(workspace) }

  def fixture = File.expand_path("fixtures/composer/account", __dir__)

  def fake = Hecks::Adapters::FakeAgent

  def asked = fake.calls.map { |call| call[:ask] }

  def body(response) = JSON.parse(response.body)

  def agents_for(name)
    Hecks::Composer::Agent.registry_with(File.join(Hecks::Composer::Agent::ADAPTERS, "#{name}.adapter"))
  end

  def ledger(dir) = File.join(dir, "ledger.bluebook")

  # The edit a good agent makes: a Refund command laid in before FreezeAccount.
  def add_refund(_prompt, dir)
    File.write(ledger(dir), File.read(ledger(dir)).sub('    command "FreezeAccount"', "#{REFUND}    command \"FreezeAccount\""))
    "Added Refund."
  end

  # The edit of an agent that gets it wrong: not a bluebook at all.
  def break_file(_prompt, dir)
    File.write(ledger(dir), "not a bluebook\n")
    "broke it"
  end

  # An agent that gets it wrong the first time and right once told why.
  def break_then_fix(prompt, dir)
    drafts = fake.calls.count { |call| call[:ask] == :draft }
    drafts == 1 ? break_file(prompt, dir) : add_refund(prompt, dir)
  end

  describe Hecks::Composer::Agent do
    it "answers a draft with the agent's note" do
      fake.edit = ->(*) { "Did it." }

      expect(described_class.draft(agents, prompt: "x", dir: workspace)).to eq("Did it.")
    end

    it "refuses an intent outside the closed set" do
      fake.intent = ->(_prompt) { "dance" }

      expect { described_class.classify(agents, prompt: "x") }.to raise_error(described_class::ValidationError, /dance/)
    end

    it "refuses a registry with no adapter for the port" do
      expect { described_class.draft(Hecks::Runtime::Registry.new, prompt: "x", dir: workspace) }
        .to raise_error(Hecks::Runtime::WiringError, /no adapter implements/)
    end
  end

  describe Hecks::Composer::Assistant do
    let(:session)   { Hecks::Composer::Session.new }
    let(:assistant) { described_class.new(workspace: workspace, agents: agents, session: session) }

    it "has the agent edit the files and checks the result", :aggregate_failures do
      fake.edit = method(:add_refund)
      result = assistant.ask("add a Refund command")

      expect(result).to include(intent: "edit", note: "Added Refund.", rounds: 1)
      expect(result[:changed].keys).to eq(["ledger.bluebook"])
      expect(result[:check][:diagrams]["Account_surface.mmd"]).to include("Refund")
    end

    it "records the conversation and the verdict on the draft", :aggregate_failures do
      fake.edit = method(:add_refund)
      assistant.ask("add a Refund command")
      held = session.summary(File.basename(workspace))

      expect(held[:status]).to eq("valid")
      expect(held[:turns].map { |turn| turn[:speaker] }).to eq(%w[author agent])
    end

    it "asks once more with the check's refusal when the first edit does not parse", :aggregate_failures do
      fake.edit = method(:break_then_fix)
      rounds = assistant.ask("add a Refund command")[:rounds]

      expect(rounds).to eq(2)
      expect(fake.calls.last[:prompt]).to include("refused by the check")
    end

    it "stops after two rounds when the repair does not pass either", :aggregate_failures do
      fake.edit = method(:break_file)
      result = assistant.ask("do something")

      expect(result[:rounds]).to eq(2)
      expect(result[:check][:diagnostic]).not_to be_nil
    end

    it "records a draft whose last edit did not pass as invalid" do
      fake.edit = method(:break_file)
      assistant.ask("do something")

      expect(session.summary(File.basename(workspace))[:status]).to eq("invalid")
    end

    it "edits nothing when the prompt reads as a question", :aggregate_failures do
      fake.intent = ->(_prompt) { "question" }

      expect(assistant.ask("what does Credit do?")).to include(intent: "question", rounds: 0, changed: {})
      expect(asked).to eq([:classify])
    end

    it "sends a wiring request to the wire ask" do
      fake.intent = ->(_prompt) { "wire" }
      assistant.ask("persist Account in postgres")

      expect(asked).to eq(%i[classify wire])
    end

    it "treats a classifier that cannot answer as an edit" do
      allow(fake).to receive(:classify).and_raise(Hecks::Composer::Agent::Unavailable, "jev is down")
      assistant.ask("add a thing")

      expect(asked).to eq([:draft])
    end
  end

  describe Hecks::Adapters::Jev do
    it "reads a choice by its key, or from a row that carries it", :aggregate_failures do
      expect(described_class.choice("edit")).to eq("edit")
      expect(described_class.choice("choice" => "wire")).to eq("wire")
    end

    it "is unavailable when jev is not installed" do
      stub_const("ENV", ENV.to_h.merge("HECKS_JEV" => "/nonexistent/jev"))

      expect { described_class.classify(prompt: "x") }
        .to raise_error(Hecks::Composer::Agent::Unavailable, /not on PATH/)
    end
  end

  describe "POST /composer/ask" do
    let(:request) { Rack::MockRequest.new(Hecks::Composer::Web.app(workspace: workspace, agents: agents)) }

    def ask(prompt) = request.post("/composer/ask", input: JSON.generate(prompt: prompt))

    it "answers what the agent changed and the check of it", :aggregate_failures do
      fake.edit = method(:add_refund)
      response = ask("add a Refund command")

      expect(response.status).to eq(200)
      expect(body(response)["changed"].keys).to eq(["ledger.bluebook"])
      expect(body(response)["check"]["diagnostic"]).to be_nil
    end

    it "proposes the panels to open for what changed" do
      fake.edit = method(:add_refund)

      expect(body(ask("add a Refund command"))["layout"]).to eq("right" => "diagram", "bottom" => "agent")
    end

    it "keeps each file the agent changed in the timeline" do
      fake.edit = method(:add_refund)
      ask("add a Refund command")
      path = JSON.generate(path: "ledger.bluebook")

      expect(body(request.post("/composer/timeline", input: path))["revisions"].first["text"]).to include("Refund")
    end

    it "keeps the conversation for the page to show" do
      fake.edit = method(:add_refund)
      ask("add a Refund command")
      turns = JSON.parse(request.get("/composer/draft").body).dig("draft", "turns")

      expect(turns.map { |turn| turn["said"] }).to eq(["add a Refund command", "Added Refund."])
    end

    it "answers 503 when the agent cannot be reached", :aggregate_failures do
      allow(fake).to receive(:draft).and_raise(Hecks::Composer::Agent::Unavailable, "claude is not on PATH")
      response = ask("x")

      expect(response.status).to eq(503)
      expect(JSON.parse(response.body)["error"]).to include("claude is not on PATH")
    end
  end
end
