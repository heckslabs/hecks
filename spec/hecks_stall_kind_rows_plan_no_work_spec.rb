require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_watch_looks"
require_relative "support/disk_space_rows"

# Stalls of one StallKind row filed straight through `Stall.File`, as the stall watch files them.
module StallKindRowLooks
  extend DiskSpaceRows

  # @return [Array<Hash>] every `StallKind` row the Hecks bluebook declares
  def self.kinds = rows("StallWatch", "StallKind").map { |row| row.to_h.transform_keys(&:to_sym) }

  # Files the stall of a row's kind once per look, each a process of its own whose Stall store
  # starts empty, as a later beat refiles a stall its store does not hold.
  def file_stall(row, looks: 1)
    looks.times do |look|
      registry.repository("Hecks", registry.bluebook("Hecks").aggregate("Stall")).reset!
      detect("look-#{look}")
      with_tap { dispatch("Hecks::Stall.File", **stall_args(row, "look-#{look}")) }
    end
  end

  def stall_args(row, watch)
    { watch: watch, stall: { value: "stall-#{row[:kind]}-w1" }, kind: { value: row[:kind] },
      subject: { value: "w1" }, opened_at: { value: "2026-11-20T00:00:00Z" }, waited: { value: 9_999 },
      minutes: { value: 0 }, forgets: { value: 99_999 }, fixer: { value: row[:fixer] },
      title: { value: row[:kind] }, detail: { value: row[:move].to_s } }
  end
end

# A stall is a signal, never work: every StallKind row, read from the bluebook so a new row is
# held to it too, files a stall that plans no Tickets work item and wakes the orchestrator once,
# however many times it is filed.
RSpec.describe "Every StallKind row as a signal" do
  include_context "with a stall watch tap"
  include StallKindRowLooks

  before { File.write(tap, "") }

  StallKindRowLooks.kinds.each do |row|
    context "with the #{row[:kind]} row" do
      it "plans no work item" do
        file_stall(row)
        expect(keys("Tickets", "Work", :work)).to be_empty
      end

      it "wakes the orchestrator once, filed twice" do
        file_stall(row, looks: 2)
        expect(events_named("CoordinatorWoken")).to eq(1)
      end
    end
  end
end
