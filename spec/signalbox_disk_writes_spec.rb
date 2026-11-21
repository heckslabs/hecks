# frozen_string_literal: true

require "spec_helper"
require "support/signalbox_asks"

# What a day of disk writes costs, by process: the pressure beat's look reads macOS's daily report
# and the free space of the disk, Signalbox records them, and a raised budget has an end.
RSpec.describe "Signalbox's disk writes" do
  include SignalboxAsks

  def allow_writes(process, megabytes, cause, ends_at)
    facts = { allowance: "#{process}:#{ends_at}", process: process, megabytes: megabytes, cause: cause,
              ends_at: ends_at, now: ends_at - 900 }
    signalbox.dispatch("Signalbox::Allowance.Set", with: facts.transform_values { |fact| { value: fact } })
  end

  before { begin_beat("beat-quiet") }

  it "records the day's writes in megabytes for each process the report names" do
    row = ask("DiskWrites.Latest").first

    expect([plain(row, :day), plain(row, :ruby_mb), plain(row, :git_mb)]).to eq(["2026-11-20", 419_211, 155_136])
  end

  it "records the disk's free space beside its size, from the beat's look" do
    row = ask("Beat.Latest").first

    expect([plain(row, :disk_free), plain(row, :disk_total)]).to eq([78_397, 471_480])
  end

  it "keeps a raise of a process's budget as a new decision with its cause and end" do
    allow_writes("ruby", 300_000, "cold boots until the resident lands", 2_000)
    allow_writes("ruby", 500_000, "a rust rebuild week", 3_000)

    expect(ask("Allowance.Of", process: { value: "ruby" }).map { |row| plain(row, :ends_at) }).to eq([3_000, 2_000])
  end
end
