require "spec_helper"

# The `CheckConclusion` rows of the Vocabulary bluebook, read through `Hecks::CheckConclusion`.
# Each flag answers one question a reader asks of a GitHub conclusion; neutral is clean but does
# not certify, so a check that reports neutral cannot stand in for a passed one.
RSpec.describe Hecks::CheckConclusion, :aggregate_failures do
  it "certifies success and skipped, but not neutral" do
    expect([%w[success skipped], ["neutral"]].map { |names| names.map { |n| described_class.certifies?(n) } })
      .to eq([[true, true], [false]])
  end

  it "counts neutral as clean, and a failure as not clean" do
    expect([described_class.clean?("neutral"), described_class.clean?("failure")]).to eq([true, false])
  end

  it "reads only success as evidence that the specs ran and passed" do
    expect(%w[success skipped neutral].map { |n| described_class.evidence?(n) }).to eq([true, false, false])
  end

  it "treats pending, empty and the unfinished conclusions as unfinished, not as failed" do
    expect([nil, "", "cancelled", "stale", "action_required"].map { |n| described_class.unfinished?(n) })
      .to all(be true)
  end

  it "answers a conclusion the table does not name as a failure on every flag" do
    expect(%w[certifies? clean? evidence? unfinished?].map { |m| described_class.public_send(m, "failure") })
      .to all(be false)
  end
end
