require "spec_helper"
require "hecks/fuzzing"
require "hecks/fuzzing/differential"

# `Differential::ServeEngine` with a scripted host-protocol client and batch run, so no kernel is
# built: which steps go over the session, which fields it answers, and how a dead kernel fails.
RSpec.describe Hecks::Fuzzing::Differential::ServeEngine do
  # A host-protocol client that records each message and answers from `replies`.
  let(:client_class) do
    Class.new do
      attr_reader :messages, :sessions, :answerer

      def initialize(answerer, replies)
        @answerer = answerer
        @replies = replies
        @messages = []
        @sessions = []
      end

      def call(message)
        @messages << message
        @replies.fetch(message.keys.find { |key| @replies.key?(key) }) { { "ok" => true } }
      end

      def open_session(name) = @sessions << name
      def close_session(name) = @sessions.delete(name)
      def close = nil
    end
  end

  let(:replies) do
    { "hello"     => { "ok" => true }, "instances" => { "ok" => true, "instances" => { "Order" => [] } },
      "verb"      => { "ok" => true, "events" => [{ "name" => "Placed" }] },
      "dry_run"   => { "verb" => "Shop::Order.Place", "ok" => true } }
  end
  let(:batch_output) { { "events" => [], "instances" => {}, "queries" => [{ "query" => "q" }], "refusals" => [] } }
  let(:batch) { ->(_domain, _steps, identity: nil) { batch_output.merge("identity" => identity) } }
  let(:steps) do
    [{ "verb" => "Shop::Order.Place", "args" => {} }, { "query" => "Shop::Order.All" },
     { "dry_run" => "Shop::Order.Place", "args" => {} }]
  end

  def engine_with(reply_table = replies)
    clients = []
    connect = ->(_binary, answerer) { client_class.new(answerer, reply_table).tap { |client| clients << client } }
    [described_class.new("/bin/kernel", batch: batch, connect: connect), clients]
  end

  it "answers instances, events and dry runs from the session, the rest from the batch run" do
    output = engine_with.first.call("examples/shop", steps)
    expect(output).to include("events"    => [{ "name" => "Placed" }], "instances" => { "Order" => [] },
                              "dry_runs"  => [replies["dry_run"]], "queries" => [{ "query" => "q" }],
                              "served"    => described_class::SERVED)
  end

  # The messages after the hello, cut to the keys that place a step.
  def sent_steps(client) = client.messages.drop(1).map { |message| message.slice("verb", "dry_run", "query", "session") }

  it "sends the verb and dry-run steps in a named session, never the query step" do
    engine, clients = engine_with
    engine.call("examples/shop", steps)
    expect(sent_steps(clients.first)).to eq([{ "verb" => "Shop::Order.Place", "session" => "sequence-1" },
                                             { "dry_run" => "Shop::Order.Place", "session" => "sequence-1" },
                                             { "session" => "sequence-1" }])
  end

  it "keeps one kernel warm across sequences and closes each sequence's session" do
    engine, clients = engine_with
    2.times { engine.call("examples/shop", steps) }
    expect([clients.size, clients.first.sessions]).to eq([1, []])
  end

  it "answers the identity fact from the sequence's script and no other fact" do
    engine, clients = engine_with
    engine.call("examples/shop", steps, identity: %w[id-1])
    answers = %w[identity_generation identity_generation now].map { |fact| clients.first.answerer.call(fact, "String", "v") }
    expect(answers).to eq(["id-1", nil, nil])
  end

  it "fails as the batch engine fails when the kernel refuses the hello" do
    engine, = engine_with(replies.merge("hello" => { "ok" => false, "error" => "no common protocol" }))
    expect { engine.call("examples/shop", steps) }
      .to raise_error(Hecks::Fuzzing::Engine::Kernel::Failed, /no common protocol/)
  end
end
