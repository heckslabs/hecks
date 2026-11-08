require "spec_helper"
require_relative "support/sweeping_fixtures"

RSpec.describe Hecks::Adapters::Sweeping, "#sweep residue" do
  include_context "with a sweep fixture"

  before { traced_log }

  it "deletes the temp files named for a removed session and no others", :aggregate_failures do
    File.write(File.join(dir, "note-aaaaaaaa.txt"), "x")
    File.write(File.join(dir, "other.txt"), "x")
    adapter.sweep(removed: "aaaaaaaa")
    expect(Dir.children(dir)).to include("other.txt").and(satisfy { |names| names.none? { |n| n.include?("note-") } })
  end

  it "reports the footprint before and after" do
    report = adapter.sweep(removed: "aaaaaaaa").dig(:report, :value)
    expect(report).to match(/\Abefore .*compressor 1 MB.*swap 250 of 1000 MB \(25%\).*after /m)
  end
end
