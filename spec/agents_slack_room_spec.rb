# frozen_string_literal: true

require "json"
require "tmpdir"
require "hecks/agents/adapters/slack_room"

# The crew room is heard: a post from the owner and one from a person reach the mail spool
# as lines addressed to the orchestrator, the references read at start and never kept.
RSpec.describe Hecks::Adapters::SlackRoom do
  let(:spool) { File.join(Dir.mktmpdir, "spool.jsonl") }
  let(:known) { { "op://Hecks/slack-crew/owner-user-id" => "UO", "op://Hecks/slack-crew/channel-id" => "C1" } }
  let(:room) { { value: "crew" } }

  def frame(user, text)
    event = { channel: "C1", user: user, text: text, client_msg_id: "m-#{user}" }
    JSON.generate(envelope_id: "e-#{user}", type: "events_api", payload: { event: event })
  end

  def heard
    frames = [frame("UO", "status?"), frame("UP", "hello")]
    socket = Class.new { define_method(:read) { frames.shift } and define_method(:write) { |_text| nil } }.new
    settings = { socket: socket, reader: ->(ref) { known.fetch(ref, "tok") }, spool: spool }
    described_class.new(settings: settings).hear(room: room)
  end

  it "sends the owner's post as the owner and a person's under their own id, both to the orchestrator" do
    heard
    lines = File.readlines(spool).map { |text| JSON.parse(text) }
    expect(lines.map { |l| l.values_at("sender", "kind", "recipient") })
      .to eq([%w[owner owner orchestrator], %w[UP person orchestrator]])
  end

  it "answers the room it heard" do
    expect(heard).to eq(room: room)
  end
end
