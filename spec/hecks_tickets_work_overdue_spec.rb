require "spec_helper"

# A started Work row with a time budget is overdue once its claim time plus the budget is before
# now, as the clock port reads it. Each example boots its own Memory domain and fixes the clock.
RSpec.describe "Work.overdue" do
  let(:hecks) { boot_hecks_in_memory }
  let(:claimed) { Time.utc(2026, 11, 1, 9, 0, 0) }

  def cli(*argv)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: ["tickets", *argv])
    out
  end

  def start(key, budget: nil)
    cli("work.plan!", "work.value=#{key}", "title.value=Step #{key}")
    cli("work.start!", "to=#{key}", "claimed_by.value=s", "claimed_at.value=#{claimed.iso8601}",
        *(budget ? ["budget_minutes.value=#{budget}"] : []))
  end

  def overdue_at(minutes_after)
    allow(Hecks::Ports::Clock).to receive(:now).and_return(claimed.to_i + (minutes_after * 60))
    cli("work.overdue").to_s.strip
  end

  it "lists a budgeted row past its budget", :aggregate_failures do
    start("late/a", budget: 30)

    expect(overdue_at(45)).to include("late/a", "15 minutes over its 30")
  end

  it "does not list a fresh budgeted row" do
    start("late/b", budget: 30)

    expect(overdue_at(10)).to eq("")
  end

  it "never lists a row with no budget" do
    start("late/c")

    expect(overdue_at(100_000)).to eq("")
  end

  it "does not list a row that is no longer started" do
    start("late/d", budget: 1)
    cli("work.finish!", "to=late/d")

    expect(overdue_at(600)).to eq("")
  end
end
