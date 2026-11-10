require "spec_helper"

# Sorting the Work queue: an open work item takes one category and one priority, neither touches the
# item's claim, step or area, and a done or dropped item takes neither. Each example boots its own
# Hecks domain, so nothing leaks between them.
RSpec.describe "Work category and priority" do
  let(:hecks) { boot_hecks_in_memory }

  def cli_text(*argv)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: ["tickets", *argv])
    out
  end

  def run_cli(*argv) = JSON.parse(cli_text(*argv))

  def plan(key, step: nil, area: nil)
    run_cli("work.plan!", "work.value=#{key}", "title.value=Step #{key}", "detail.value=Brief #{key}",
            *(step ? ["step.value=#{step}"] : []), *(area ? ["area=#{area}"] : []))
  end

  def categorize(key, category) = cli_text("work.categorize!", "to=#{key}", "category.value=#{category}")

  def prioritize(key, priority) = cli_text("work.prioritize!", "to=#{key}", "priority.value=#{priority}")

  def row(key) = run_cli("work.undone").find { |found| found["work"] == key }

  def started_row(key)
    run_cli("work.start!", "to=#{key}", "claimed_by.value=session-a", "claimed_at.value=2026-11-03T09:00:00Z")
    row(key)
  end

  it "sorts a planned item into a category", :aggregate_failures do
    plan("work/a")
    categorize("work/a", "delivery")

    expect(row("work/a")["category"]).to eq("delivery")
  end

  it "takes each of the eight themes as a category", :aggregate_failures do
    themes = %w[agent-roles-and-handoff autonomous-pipeline pipeline-board landing-review-and-train
                bluebook-gaps-and-tool-dissolve kernel-parity-and-simulation docs-and-interviews side-projects]
    themes.each_with_index do |theme, index|
      plan("work/theme-#{index}")
      categorize("work/theme-#{index}", theme)

      expect(row("work/theme-#{index}")["category"]).to eq(theme)
    end
  end

  it "gives a planned item a priority" do
    plan("work/a")
    prioritize("work/a", "now")

    expect(row("work/a")["priority"]).to eq("now")
  end

  it "leaves a new item with neither" do
    plan("work/a")

    expect(row("work/a").values_at("category", "priority")).to eq([nil, nil])
  end

  it "refuses a category the list does not name" do
    plan("work/a")

    expect(categorize("work/a", "gardening")).to match(/invariant_violation\] Category admits .*"tooling".*got "gardening"/)
  end

  it "refuses a priority the list does not name" do
    plan("work/a")

    expect(prioritize("work/a", "someday")).to match(/invariant_violation\] Priority admits .*"later".*got "someday"/)
  end

  it "takes a new category and replaces the old one" do
    plan("work/a")
    categorize("work/a", "coder")
    categorize("work/a", "host")

    expect(row("work/a")["category"]).to eq("host")
  end

  it "categorizes a started item without touching its claim", :aggregate_failures do
    plan("work/a")
    started_row("work/a")
    categorize("work/a", "language")

    expect(row("work/a").values_at("status", "claimed_by", "category")).to eq(%w[started session-a language])
  end

  it "leaves the step and the area as they were", :aggregate_failures do
    plan("work/a", step: 3, area: "lib/hecks/tickets")
    prioritize("work/a", "next")
    categorize("work/a", "tooling")

    expect(row("work/a").values_at("step", "area")).to eq([3, ["lib/hecks/tickets"]])
  end

  it "refuses to categorize a done item" do
    plan("work/a")
    run_cli("work.finish!", "to=work/a")

    expect(categorize("work/a", "coder")).to include("a done or dropped work item takes no category")
  end

  it "refuses to prioritize a dropped item" do
    plan("work/a")
    run_cli("work.drop!", "to=work/a", "reason.value=not needed")

    expect(prioritize("work/a", "now")).to include("a done or dropped work item takes no priority")
  end

  it "lists the open items of one tier" do
    %w[a b c].each { |key| plan("work/#{key}") }
    prioritize("work/a", "now")
    prioritize("work/b", "later")

    expect(run_cli("work.undone_in_tier", "tier=now").map { |found| found["work"] }).to eq(["work/a"])
  end

  it "lists the open items of one category" do
    %w[a b c].each { |key| plan("work/#{key}") }
    categorize("work/a", "parity")
    categorize("work/c", "parity")

    expect(run_cli("work.undone_in_category", "kind=parity").map { |found| found["work"] }).to eq(%w[work/a work/c])
  end

  it "keeps a done item out of the tier list" do
    plan("work/a")
    prioritize("work/a", "now")
    run_cli("work.finish!", "to=work/a")

    expect(run_cli("work.undone_in_tier", "tier=now")).to be_empty
  end

  it "leaves the three plan-order reads in plan order", :aggregate_failures do
    plan("work/late", step: 2)
    plan("work/early", step: 1)
    prioritize("work/late", "now")

    expect(run_cli("work.undone").map { |found| found["work"] }).to eq(%w[work/early work/late])
    expect(run_cli("work.next_planned").first["work"]).to eq("work/early")
  end
end
