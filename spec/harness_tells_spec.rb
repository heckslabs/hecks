require "spec_helper"
require "hecks/harness/tells"

# Each tell the supervisor writes becomes the Harness command that records it, or none.
RSpec.describe Hecks::Harness::Tells do
  def commands(tell) = described_class.commands(tell)

  it "posts a sent message with its moment on the supervisor's clock" do
    tell = { "tell" => "sent", "at_ms" => 67, "session" => "reviewer", "message" => "reviewer-1",
             "to" => "coder", "text" => "hi" }
    posted = { key: { value: "reviewer-1" }, sender: { value: "reviewer" }, addressee: { value: "coder" },
               text: { value: "hi" }, sent_at: { value: 67 } }
    expect(commands(tell)).to eq([["Message.Post", posted]])
  end

  it "records a stopped session, and each message it still held as undeliverable" do
    tell = { "tell" => "stopped", "session" => "coder", "code" => nil, "undelivered" => ["reviewer-4"] }
    expect(commands(tell)).to eq([["Session.RecordStopped", { session: "coder", code: { value: "" } }],
                                  ["Message.RecordUndeliverable", { message: "reviewer-4" }]])
  end

  it "records a failed turn as an error" do
    expect(commands({ "tell" => "turn_ended", "session" => "coder", "is_error" => true, "text" => "" }).dig(0, 1, :outcome))
      .to eq({ value: "error" })
  end

  it "records nothing for a tell that only answers an op" do
    expect(%w[ready opened queued refused quit].flat_map { |kind| commands({ "tell" => kind }) }).to be_empty
  end
end
