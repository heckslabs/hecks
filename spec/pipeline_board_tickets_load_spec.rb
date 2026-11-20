# frozen_string_literal: true

require "spec_helper"
require "json"
require "hecks/pipeline_board/adapters/pipeline_tickets"

# The board's Tickets reader with no live store, over a Hecks domain booted in Memory: what is
# undone and how many items stand in each status are what the Tickets bluebook's own `Work.Undone`
# query and `WorkByStatus` read model answer, so the board holds no status list of its own.
RSpec.describe Hecks::Adapters::PipelineTickets do
  let(:hecks) { boot_hecks_in_memory }
  let(:tickets) { described_class.new(registry: hecks.registry, settings: { live_store: nil }) }

  def cli(*argv)
    Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: ["tickets", *argv]).first
  end

  def plan(key, step) = cli("work.plan!", "work.value=#{key}", "title.value=Item #{key}", "step.value=#{step}")

  def open_slugs = tickets.open_work.map { |item| item[:slug] }

  # Two items planned out of plan order, and a third that is finished.
  def three_items
    plan("board/later", 2)
    plan("board/sooner", 1)
    plan("board/finished", 3)
    cli("work.finish!", "to=board/finished", "no_change.value=a verify")
  end

  it "answers the undone Work items in plan order, as Work.Undone does" do
    three_items
    expect(open_slugs).to eq(%w[board/sooner board/later])
  end

  it "counts every status, as the WorkByStatus read model does" do
    three_items
    expect(tickets.counts).to eq("planned" => 2, "done" => 1)
  end

  it "answers no open work, and no error, when every Work item is done" do
    plan("board/only", 1)
    cli("work.finish!", "to=board/only", "no_change.value=a verify")
    expect(open_slugs).to eq([])
  end

  def report(key, source) = cli("finding.report!", "finding.value=#{key}", "title.value=Stop #{key}", "source.value=#{source}")

  it "answers the stopped runs and the open findings, as Finding.Stopped and Finding.Open do", :aggregate_failures do
    report("run-b", "pipeline")
    report("seen-a", "maintainer")
    expect(tickets.stopped_runs.map { |run| run[:finding] }).to eq(["run-b"])
    expect(tickets.open_findings.map { |finding| finding[:finding] }).to eq(%w[run-b seen-a])
  end

  it "says the store holds no Work items when it holds none at all" do
    expect { tickets.open_work }.to raise_error(Hecks::Adapters::PipelineBoard::Unavailable, /holds no Work items/)
  end

  it "says the registry declares no such reading when the domain is not booted here" do
    bare = described_class.new(settings: { live_store: nil })
    expect { bare.counts }.to raise_error(Hecks::Adapters::PipelineBoard::Unavailable, /declares no Tickets.Work/)
  end
end
