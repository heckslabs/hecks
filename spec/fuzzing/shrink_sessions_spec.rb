require "spec_helper"
require "hecks/fuzzing"
require "hecks/fuzzing/differential"

# `Differential::ShrinkSessions` with a scripted host-protocol client and a stubbed Ruby replay, so
# no kernel is built: which findings it judges, the eager hello, one warm kernel with a session
# per candidate, and the served fields compared as `Differential.diff` compares them.
RSpec.describe Hecks::Fuzzing::Differential::ShrinkSessions do
  # A host-protocol client that answers from `replies` and records its sessions; a stalled one
  # reads its hello's answer from a pipe nothing writes, as a binary that reads all stdin first.
  let(:client_class) do
    Class.new do
      attr_reader :opened, :closed

      def initialize(replies, stall: false)
        @replies = replies
        @stall = stall
        @opened = []
        @closed = false
      end

      def call(message)
        @pipe = IO.pipe if @stall && message.key?("hello")
        @pipe&.first&.read
        @replies.fetch(message.keys.find { |key| @replies.key?(key) }) { { "ok" => true } }
      end

      def open_session(name) = @opened << name
      def close_session(_name) = nil

      def close
        @pipe&.each(&:close)
        @closed = true
      end
    end
  end

  let(:replies) do
    { "hello" => { "ok" => true }, "instances" => { "ok" => true, "instances" => { "Shop::Order#1" => { "n" => 1 } } },
      "verb"  => { "ok" => true, "events" => [{ "name" => "Placed" }] },
      "dry_run" => { "verb" => "Shop::Order.Place", "ok" => true, "extra" => 1 } }
  end
  let(:differ) do
    Class.new do
      def strip_emitted_flags!(value) = value
      def strip_occurred_at!(value) = value
    end.new
  end
  let(:steps) { [{ "verb" => "Shop::Order.Place", "args" => {} }, { "dry_run" => "Shop::Order.Place", "args" => {} }] }
  let(:ruby_result) do
    { instances: { "Shop::Order#1" => { "n" => 1 } }, events: [{ "name" => "Placed" }], refusals: [], queries: [],
      sagas: [], dry_runs: [{ verb: "Shop::Order.Place", ok: true }] }
  end

  before { allow(Hecks::Fuzzing::Replay).to receive(:call).and_return(ruby_result) }

  def open_with(reply_table = replies, stall: false)
    clients = []
    connect = ->(_binary, _answerer) { client_class.new(reply_table, stall: stall).tap { |client| clients << client } }
    [described_class.open("/bin/kernel", differ: differ, domain_path: "examples/shop", connect: connect), clients]
  end

  it "judges a finding whose every key names a served field, and no other", :aggregate_failures do
    expect(described_class.servable?(Set["events", "instances:Shop::Order", "dry_runs"])).to be(true)
    expect(described_class.servable?(Set["events", "refusals:Shop::Order.Place"])).to be(false)
    expect(described_class.servable?(Set[])).to be(false)
  end

  it "finds no divergence where the session answers as Ruby, comparing dry runs by verb and ok" do
    expect(open_with.first.divergences(steps)).to eq([])
  end

  it "names each served field the session answers differently" do
    allow(Hecks::Fuzzing::Replay).to receive(:call).and_return(ruby_result.merge(events: [], dry_runs: []))
    expect(open_with.first.divergences(steps).map { |divergence| divergence[:field] }).to eq(%w[events dry_runs])
  end

  it "keeps one kernel warm and gives the hello and each candidate a fresh session" do
    sessions, clients = open_with
    2.times { sessions.divergences(steps) }
    expect([clients.size, clients.first.opened]).to eq([1, %w[sequence-1 sequence-2 sequence-3]])
  end

  it "refuses a kernel that refuses the hello, by name, at open" do
    refusing = replies.merge("hello" => { "ok" => false, "error" => "no common protocol" })
    expect { open_with(refusing) }.to raise_error(described_class::Unserved, /no common protocol/)
  end

  it "refuses a binary whose hello never answers, and closes it" do
    stub_const("#{described_class}::HELLO_WAIT", 0.05)
    clients = []
    connect = ->(_binary, _answerer) { client_class.new(replies, stall: true).tap { |client| clients << client } }
    expect { described_class.open("/bin/fixture", differ: differ, domain_path: "d", connect: connect) }
      .to raise_error(described_class::Unserved).and(change { clients.map(&:closed) }.to([true]))
  end
end
