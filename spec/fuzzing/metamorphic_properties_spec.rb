require "spec_helper"
require "hecks/fuzzing/properties/metamorphic"

# The metamorphic properties over a scripted serve kernel, so no cargo build runs: an honest
# kernel passes every one, each planted fault fails the properties it names, and the census's
# 18 (b) and (c) properties are each placed once.
RSpec.describe Hecks::Fuzzing::Properties::Metamorphic do
  # A kernel of one aggregate over the serve protocol: `Make` stores a record under an id it asks
  # the host for, `Fail` is refused, and sessions, snapshots and dry runs behave as `cli.rs` says.
  let(:kernel_class) do
    Class.new do
      def initialize(answerer)
        @answerer = answerer
        @sessions = { nil => { store: [], snapshot: nil } }
      end

      def call(message)
        return { "ok" => true } if message.key?("hello")
        return @sessions.store(message["open"], { store: [], snapshot: nil }) && { "ok" => true } if message.key?("open")
        return @sessions.delete(message["close"]) && { "ok" => true } if message.key?("close")

        step(@sessions.fetch(message["session"]), message)
      end

      def close = nil

      private

      def step(session, message)
        if message.key?("instances") then { "ok" => true, "instances" => { "Item" => session[:store].dup } }
        elsif message.key?("dry_run") then { "ok" => message["dry_run"] != "Fail" }
        elsif message.key?("verb") then dispatch(session, message["verb"])
        else keep(session, message)
        end
      end

      def keep(session, message)
        message.key?("snapshot") ? session[:snapshot] = session[:store].dup : session[:store] = session[:snapshot].dup
        { "ok" => true }
      end

      def dispatch(session, verb)
        return { "ok" => false, "error" => "refused" } if verb == "Fail"

        session[:store] << { "id" => @answerer.call("identity_generation", "String", verb) }
        { "ok" => true, "events" => [{ "name" => "Made" }] }
      end
    end
  end

  let(:steps) { %w[Make Fail Make Make Fail Make].map { |verb| { "verb" => verb, "args" => {} } } }

  def probe(fault = nil)
    wrap = fault ? described_class::Faults.wrap(fault) : :itself.to_proc
    described_class::Probe.new(->(answerer) { wrap.call(kernel_class.new(answerer)) }, {})
  end

  it "passes every property on an honest kernel" do
    expect(described_class.check(probe, steps).values.uniq).to eq([true])
  end

  described_class::Faults::CATALOG.each_key do |fault|
    it "fails #{described_class::Faults.trips(fault).join(" and ")} when #{fault} is planted" do
      failed = described_class.check(probe(fault), steps).reject { |_name, verdict| verdict == true }.keys
      expect(described_class::Faults.trips(fault) - failed).to be_empty
    end
  end

  it "names the refused step a planted write follows" do
    verdict = described_class::RefusalsLeaveTheStoreIdentical.call(probe(:refusal_writes), steps)
    expect(verdict).to eq("refused step 1 (Fail) changed the store")
  end

  it "plays only the verb and dry-run steps of a corpus script" do
    script = [{ "verb" => "Make", "args" => {} }, { "query" => "Q" }, { "dry_run" => "Make", "expect" => 1 }]
    expect(described_class::Probe.playable(script)).to eq([{ "verb" => "Make", "args" => {} }, { "dry_run" => "Make" }])
  end

  it "hands a session given an id script exactly those ids" do
    honest = probe
    expect(honest.session(ids: %w[kept]) { |name| honest.send_step(name, steps.first).ids }).to eq(%w[kept])
  end

  it "places each of the census's 18 (b) and (c) properties exactly once" do
    expect(described_class::Census.placed.tally.values.uniq).to eq([1])
  end

  it "rewrites the census properties only into properties that exist" do
    expect(described_class::Census::REWRITES.values.map { |row| row[:to] } - described_class::NAMES).to be_empty
  end
end
