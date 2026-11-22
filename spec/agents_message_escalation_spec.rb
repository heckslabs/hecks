require "spec_helper"
require_relative "support/agents_message_helpers"

# A coder's question to the orchestrator waits with the scrum master, and what it leaves unsettled
# for fifteen minutes reaches the lead, whether or not a scrum master session has registered.
RSpec.describe "the Agents message escalation" do
  include AgentsMessageHelpers

  before { boot_messages }

  def recipients = {}

  def ask(key = "q1") = send_message(key: key, to: "orchestrator", sender: "coder-a", kind: "question", asker: "coder")

  def escalate(key, now) = Hecks::Agents::Message.find(key).escalate!(now: { value: now })

  it "holds a coder's question for the scrum master" do
    expect(ask.recipient.value).to eq("scrum-master")
  end

  it "hands a held question to the lead after fifteen minutes", :aggregate_failures do
    ask
    escalated = escalate("q1", 2_000)
    expect(escalated.recipient.value).to eq("orchestrator")
    expect(escalated.status).to eq("sent")
  end

  it "refuses to hand on a question inside its window" do
    ask
    expect { escalate("q1", 1_500) }.to raise_error(Hecks::Runtime::GivenNotMet, /fifteen minutes/)
  end

  it "refuses to hand on a message no coder asked" do
    send_message(key: "a1", to: "scrum-master", sender: "orchestrator")
    expect { escalate("a1", 9_000) }.to raise_error(Hecks::Runtime::GivenNotMet, /a coder asked/)
  end

  it "lists a held question among the unsettled" do
    ask
    expect(Hecks::Agents::Message.unsettled.map { |row| row[:message].value }).to eq(["q1"])
  end

  it "refuses findings on a question the scrum master does not hold" do
    send_message(key: "s1", to: "orchestrator", sender: "staff-engineer", kind: "question", asker: "staff-engineer")
    expect { Hecks::Agents::Message.find("s1").note!(findings: { value: "x" }) }
      .to raise_error(Hecks::Runtime::GivenNotMet, /scrum master holds/)
  end

  it "refuses findings that say nothing" do
    ask
    expect { Hecks::Agents::Message.find("q1").note!(findings: { value: " " }) }
      .to raise_error(Hecks::Runtime::GivenNotMet, /findings say something/)
  end

  it "leaves a staff engineer's question with the orchestrator" do
    send_message(key: "s2", to: "orchestrator", sender: "staff-engineer", kind: "question", asker: "staff-engineer")
    expect(inbox("orchestrator")).to eq(["s2"])
  end

  context "with a scrum master registered" do
    def recipients = { "scrum-master" => live_run, "orchestrator" => live_run }

    it "hands on a question the scrum master heard and did not answer", :aggregate_failures do
      ask.receive!(reader: { value: "scrum-master" })
      expect(Hecks::Agents::Message.find("q1").status).to eq("read")
      expect(escalate("q1", 2_000).recipient.value).to eq("orchestrator")
    end

    it "takes findings on a question already heard" do
      ask.receive!(reader: { value: "scrum-master" })
      note = Hecks::Agents::Message.find("q1").note!(findings: { value: "no rule answers it" })
      expect(note.findings.value).to eq("no rule answers it")
    end

    it "does not hand on a question the scrum master answered", :aggregate_failures do
      ask.receive!(reader: { value: "scrum-master" })
      send_message(key: "a2", to: "coder-a", sender: "scrum-master", kind: "answer", reply: "q1")
      expect(Hecks::Agents::Message.unsettled).to be_empty
      expect { escalate("q1", 2_000) }.to raise_error(Hecks::Runtime::GivenNotMet, /not answered/)
    end
  end
end
