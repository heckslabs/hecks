require "spec_helper"
require "socket"
require "hecks/adapters/driving/resident/server"

# The time limit of a resident's forked line (ADR 0201): the Hecks world may set `line_seconds`,
# and a child still running after it is ended, its whole group with it, with the reason on its
# caller's standard error. A world that sets none leaves a line the default limit. The signals
# and the waits are stood in for; one example forks a real child that ends at once.
RSpec.describe Hecks::Adapters::Driving::Resident::LineLimit do
  let(:server) { Hecks::Adapters::Driving::Resident::Server.new("/checkout", "/checkout/exe/hecks") }
  let(:signals) { [] }
  let(:sleeps) { [] }
  let(:said) { StringIO.new }

  before do
    allow(Process).to receive(:kill) { |signal, pid| signals << [signal, pid] }
    allow(server).to receive(:sleep) { |seconds| sleeps << seconds }
  end

  def limit(seconds)
    server.instance_variable_set(:@settings, { idle_seconds: 600.0, line_seconds: seconds }.compact)
  end

  # The world as the resident's loaded domain answers it, declaring the given `resident` line.
  def world_declaring(line)
    world = Struct.new(:line) { def for_verb(_verb) = line }.new(line)
    registry = Struct.new(:found) { def world(_name) = found }.new(world)
    cache = Struct.new(:registry) { def fetch(*) = self }.new(registry)
    server.instance_variable_set(:@cache, cache)
    server.send(:settings)
  end

  it "ends the child's whole group, INT then TERM then KILL, once the limit has passed", :aggregate_failures do
    limit(30.0)
    server.send(:end_when_overdue, 4242, said)
    expect(sleeps).to eq([30.0, 0, 5, 10])
    expect(signals).to eq([["INT", -4242], ["TERM", -4242], ["KILL", -4242]])
  end

  it "tells the caller which limit ended its line" do
    limit(30.0)
    server.send(:end_when_overdue, 4242, said)
    expect(said.string).to include("line 4242 ran past the resident's limit of 30 seconds")
  end

  it "still ends the line when the caller cannot be told" do
    limit(30.0)
    server.send(:end_when_overdue, 4242, StringIO.new.tap(&:close))
    expect(signals.last).to eq(["KILL", -4242])
  end

  it "signals nothing and waits for nothing when the world sets no limit", :aggregate_failures do
    limit(nil)
    server.send(:end_when_overdue, 4242, said)
    expect(signals).to be_empty
    expect(sleeps).to be_empty
  end

  it "keeps the caller's standard error, and closes the rest, when a limit is set", :aggregate_failures do
    limit(30.0)
    streams = Array.new(3) { StringIO.new }
    expect(server.send(:keep_for_limit, streams)).to be(streams.last)
    expect(streams.map(&:closed?)).to eq([true, true, false])
  end

  it "closes all three of the caller's streams when no limit is set", :aggregate_failures do
    limit(nil)
    streams = Array.new(3) { StringIO.new }
    expect(server.send(:keep_for_limit, streams)).to be_nil
    expect(streams.map(&:closed?)).to eq([true, true, true])
  end

  it "reads the limit from the world's resident line" do
    expect(world_declaring({ line_seconds: 1800 })[:line_seconds]).to eq(1800.0)
  end

  it "has the default limit when the world's resident line names none" do
    expect(world_declaring({ idle_seconds: 600 })[:line_seconds]).to eq(1800.0)
  end

  it "lets go of the kept stream, and reports the status, when the child leaves first", :aggregate_failures do
    limit(30.0)
    caller_end, client = UNIXSocket.pair
    server.send(:monitor, fork { exit!(3) }, client, StringIO.new, said)
    expect(caller_end.gets).to eq("status:3\n")
    expect(said).to be_closed
  end
end
