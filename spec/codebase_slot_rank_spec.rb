# frozen_string_literal: true

require "spec_helper"
require_relative "support/slot_queue_waiters"

# Which waiter goes first when a retry keeps its first arrival or a landing has waited long.
RSpec.describe Hecks::Adapters::Codebase::SlotQueue, ".priority_of" do
  include SlotQueueWaiters

  let(:dir) { Dir.mktmpdir("slot-queue") }
  let(:landing) { { "HECKS_HEAVY_KIND" => "landing" } }

  after { FileUtils.rm_rf(dir) }

  # The environment of a waiter that first arrived `minutes` ago.
  def arrived(minutes, base = {})
    ns = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond) - (minutes * 60 * 1_000_000_000)
    base.merge("HECKS_HEAVY_ARRIVAL" => ns.to_s)
  end

  it "keeps a rejoining waiter's first arrival, so it stays ahead of jobs that came after it" do
    expect(run_waiters([{ name: :a }, { name: :b }, { name: :retry, base: arrived(60) }])).to eq(%i[retry a b])
  end

  it "ranks a landing behind an older ordinary job until it has waited twenty minutes" do
    waiters = [{ name: :spec, base: arrived(15) }, { name: :landing, base: arrived(10, landing) }]
    expect(run_waiters(waiters)).to eq(%i[spec landing])
  end

  it "lets a landing that has waited twenty minutes pass an ordinary job that arrived before it" do
    waiters = [{ name: :spec, base: arrived(30) }, { name: :landing, base: arrived(25, landing) }]
    expect(run_waiters(waiters)).to eq(%i[landing spec])
  end

  it "keeps an aged landing behind an urgent job" do
    urgent = { "HECKS_HEAVY_PRIORITY" => "urgent" }
    waiters = [{ name: :landing, base: arrived(25, landing) }, { name: :urgent, base: urgent }]
    expect(run_waiters(waiters)).to eq(%i[urgent landing])
  end

  it "clears the carried arrival once the job has held a place" do
    base = arrived(1)
    run_waiters([{ name: :a, base: base }])
    expect(base).not_to have_key("HECKS_HEAVY_ARRIVAL")
  end
end
