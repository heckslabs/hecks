# frozen_string_literal: true

require "spec_helper"
require_relative "support/slot_queue_waiters"

# The line for the heavy-job place: waiters take it in arrival order, a job of the push train's push
# goes ahead of the others, and the ticket of a waiter that died never blocks the line.
RSpec.describe Hecks::Adapters::Codebase::SlotQueue do
  include SlotQueueWaiters

  let(:dir) { Dir.mktmpdir("slot-queue") }
  let(:train_base) { { "GIT_CONFIG_PARAMETERS" => "'hecks.trainCarry=abc123'" } }
  let(:urgent_base) { { "HECKS_HEAVY_PRIORITY" => "urgent" } }

  after { FileUtils.rm_rf(dir) }

  it "gives the place to three waiters in the order they arrived" do
    expect(run_waiters(%i[first second third].map { |name| { name: name } })).to eq(%i[first second third])
  end

  it "lets a train's job go ahead of a landing's gate that arrived earlier" do
    expect(run_waiters([{ name: :landing }, { name: :train, base: train_base }])).to eq(%i[train landing])
  end

  it "lets an urgent job go ahead of ordinary waiters that arrived earlier" do
    expect(run_waiters([{ name: :a }, { name: :b }, { name: :urgent, base: urgent_base }])).to eq(%i[urgent a b])
  end

  it "keeps an urgent job behind a train's job that arrived later" do
    waiters = [{ name: :urgent, base: urgent_base }, { name: :train, base: train_base }]
    expect(run_waiters(waiters)).to eq(%i[train urgent])
  end

  it "never lets an ordinary job that arrives later overtake an urgent one" do
    expect(run_waiters([{ name: :urgent, base: urgent_base }, { name: :late }])).to eq(%i[urgent late])
  end

  it "is not held up by the ticket of a waiter that died" do
    FileUtils.mkdir_p(File.join(dir, "waiting"))
    File.write(File.join(dir, "waiting", "2-#{"0" * 20}-0000000001"), "")
    expect(run_waiters([{ name: :live }])).to eq([:live])
  end

  # A place file, as a waiter holds one it has just locked.
  def place = File.new(File.join(dir, "slot-0.lock"), File::CREAT | File::RDWR)

  it "lets a place it took go when a ticket ahead joined after it looked at the line" do
    ordinary = described_class.new(dir).join
    train = described_class.new(dir, priority: described_class::TRAIN).join
    taken = place
    expect([ordinary.keep(taken), taken.closed?, train.keep(place)]).to match([nil, true, an_instance_of(File)])
  end

  it "leaves no ticket behind once every waiter has run", :aggregate_failures do
    run_waiters([{ name: :a }, { name: :b }])
    expect(Dir.children(File.join(dir, "waiting"))).to eq([])
    expect(File.read(File.join(dir, "slot-0.lock"))).to eq("")
  end
end
