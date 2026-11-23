# frozen_string_literal: true

require "tmpdir"
require "hecks/agents/adapters/slack_listener"

RSpec.describe Hecks::Adapters::SlackListener do
  let(:spool) { File.join(Dir.mktmpdir, "mail", "spool.jsonl") }
  let(:post) { Hecks::Adapters::SlackPost.new(owner: "UOWNER", channel: "CCREW", agents: %w[lead]) }
  let(:sent) { [] }

  def envelope(id, user, text)
    event = { "channel" => "CCREW", "user" => user, "text" => text, "client_msg_id" => id }
    JSON.generate(envelope_id: "e-#{id}", type: "events_api", payload: { event: event })
  end

  def socket(*frames)
    written = sent
    Class.new do
      define_method(:read) { frames.shift }
      define_method(:write) { |text| written << text }
    end.new
  end

  def lines = File.readlines(spool).map { |text| JSON.parse(text) }

  it "appends the owner's post and a person's post to the spool" do
    described_class.new(socket: socket(envelope("a", "UOWNER", "hi"), envelope("b", "UDANA", "yo")),
                        post: post, spool: spool).run
    expect(lines.map { |line| line.values_at("sender", "kind") }).to eq([%w[owner owner], %w[UDANA person]])
  end

  it "acknowledges each envelope" do
    described_class.new(socket: socket(envelope("a", "UDANA", "hi")), post: post, spool: spool).run
    expect(sent).to eq([JSON.generate(envelope_id: "e-a")])
  end

  it "appends a replayed post once" do
    described_class.new(socket: socket(envelope("a", "UDANA", "hi"), envelope("a", "UDANA", "hi")),
                        post: post, spool: spool).run
    expect(lines.size).to eq(1)
  end

  it "appends nothing for a hello frame" do
    described_class.new(socket: socket(JSON.generate(type: "hello")), post: post, spool: spool).run
    expect(File.exist?(spool)).to be(false)
  end
end
