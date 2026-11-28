require "spec_helper"
require "hecks/harness/tells"

# Each tell the supervisor writes becomes the Harness command that records it, or none.
RSpec.describe Hecks::Harness::Tells do
  def commands(tell) = described_class.commands(tell)

  it "posts a sent message with its moment on the supervisor's clock" do
    tell = { "tell" => "sent", "at_ms" => 67, "session" => "reviewer", "message" => "reviewer-1",
             "to" => "coder", "text" => "hi" }
    posted = { key: { value: "reviewer-1" }, sender: { value: "reviewer" }, addressee: { value: "coder" },
               text: { value: "hi" }, sent_at: { value: 67 }, about: nil, urgency: { value: "normal" } }
    expect(commands(tell)).to eq([["Message.Post", posted]])
  end

  it "posts a message sent about another with the key it answers" do
    tell = { "tell" => "sent", "at_ms" => 90, "session" => "coder", "message" => "coder-1",
             "to" => "reviewer", "text" => "yes", "about" => "reviewer-1" }
    expect(commands(tell).dig(0, 1, :about)).to eq({ value: "reviewer-1" })
  end

  it "posts a message sent urgent as urgent" do
    tell = { "tell" => "sent", "at_ms" => 95, "session" => "lead", "message" => "lead-1",
             "to" => "worker", "text" => "stop", "urgent" => true }
    expect(commands(tell).dig(0, 1, :urgency)).to eq({ value: "urgent" })
  end

  it "records the turn an urgent message cut short, by the message's key" do
    expect(commands({ "tell" => "interrupted", "session" => "worker", "message" => "lead-1" }))
      .to eq([["Session.RecordInterrupted", { session: "worker", cutter: { value: "lead-1" } }]])
  end

  it "records a stopped session, and each message it still held as undeliverable" do
    tell = { "tell" => "stopped", "session" => "coder", "code" => nil, "undelivered" => ["reviewer-4"] }
    expect(commands(tell)).to eq([["Session.RecordStopped", { session: "coder", code: { value: "" } }],
                                  ["Message.RecordUndeliverable", { message: "reviewer-4" }]])
  end

  it "records a tick of the supervisor's clock at its moment" do
    expect(commands({ "tell" => "tick", "at_ms" => 60_000 }))
      .to eq([["Clock.Tick", { reading: { value: "tick-60000" }, now: { value: 60_000 } }]])
  end

  it "records a failed turn as an error" do
    expect(commands({ "tell" => "turn_ended", "session" => "coder", "is_error" => true, "text" => "" }).dig(0, 1, :outcome))
      .to eq({ value: "error" })
  end

  it "records a refused tool with the role that lacks it and the reason" do
    tell = { "tell" => "denied", "session" => "reviewer", "tool" => "Bash", "role" => "reviewer",
             "reason" => "Bash is withheld from reviewer" }
    expect(commands(tell)).to eq([["Session.RecordWithheld",
                                   { session: "reviewer", tool: { value: "Bash" }, role: { value: "reviewer" },
                                     reason: { value: "Bash is withheld from reviewer" } }]])
  end

  it "records an allowed tool with the role that holds it" do
    tell = { "tell" => "allowed", "session" => "reviewer", "tool" => "Read", "role" => "reviewer" }
    expect(commands(tell).dig(0, 1, :role)).to eq({ value: "reviewer" })
  end

  it "records a refused tool of a session with no role without one" do
    tell = { "tell" => "denied", "session" => "ad-hoc", "tool" => "Bash", "reason" => "Bash is withheld" }
    expect(commands(tell).dig(0, 1, :role)).to be_nil
  end

  it "records nothing for a tell that only answers an op" do
    expect(%w[ready opened queued noticed refused quit].flat_map { |kind| commands({ "tell" => kind }) }).to be_empty
  end
end
