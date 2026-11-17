require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A fill that started nothing says why in its header, so a roll that does not fill records the step
# that ended it: the waits grouped by kind, and the planned items a roll leaves out unmarked.
RSpec.describe Hecks::Adapters::Dispatching::StopReason do
  def skip(reason) = Hecks::Adapters::Dispatching::Plan::Skip.new("k", reason)

  def clause(**given) = described_class.new(skipped: [], unmarked: 0, chosen: 0, **given).clause

  it "says nothing when something started" do
    expect(clause(chosen: 1)).to eq("")
  end

  it "groups the waits by kind", :aggregate_failures do
    text = clause(skipped: [skip("skipped: cap 4 reached (4 started, 0 chosen by this fill)"), skip("skipped: load 22.0 > 20.5"),
                            skip("skipped: cap 4 reached (4 started, 0 chosen by this fill)")])

    expect(text).to include("nothing started", "2 held by cap", "1 held by load")
  end

  it "counts the planned items a roll leaves out for want of a priority" do
    expect(clause(unmarked: 3)).to include("3 planned without a priority wait for a manual fill")
  end

  it "says when nothing was planned" do
    expect(clause).to include("nothing planned")
  end
end
