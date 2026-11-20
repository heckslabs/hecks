# frozen_string_literal: true

require "spec_helper"
require_relative "support/project_board_fixture"
require "hecks/pipeline_board/adapters/pipeline_tickets"

# The Tickets port's `ProjectWork`: the chosen `ProjectBoard` row's epics and undone Work items.
# Another project's are read from its own store, undone by the Tickets bluebook's `Work.Undone`.
RSpec.describe Hecks::Adapters::PipelineTickets, "#project_work" do
  subject(:tickets) { described_class.new(settings: { work_items: own, epics: [], projects_dir: projects }) }

  let(:projects) { Dir.mktmpdir("project-boards") }
  let(:own) { [{ slug: "hecks-item", status: "planned" }] }
  let(:works) do
    [["later", "planned", 3, "growth"], ["sooner", "started", 1, nil], ["shipped", "done", 2, nil],
     ["dropped-one", "dropped", 4, nil], ["gone", "lapsed", 5, nil]]
  end

  before { ProjectBoardFixture.checkout(projects, works: works) }
  after { FileUtils.rm_rf(projects) }

  def read(name) = tickets.project_plan(name)

  it "answers the project as WorkLine rows when it is asked as a query" do
    expect(tickets.project_work(project: { value: "Shorts" }).map { |row| row[:slug] }).to eq(%w[sooner later])
  end

  it "refuses the query, with the reason, for a name no ProjectBoard row holds" do
    expect { tickets.project_work(project: "Nowhere") }
      .to raise_error(Hecks::Adapters::PipelineBoard::Unavailable, /no project board is named Nowhere/)
  end

  it "answers another project's undone items in plan order, by the Work.Undone rule" do
    expect(read("Shorts")[:items].map { |item| item[:slug] }).to eq(%w[sooner later])
  end

  it "answers another project's epics with their closed counts" do
    expect(read("Shorts")[:epics].first).to include(epic: "growth", title: "Grow", done: 0)
  end

  it "answers the board's own project from its own reader" do
    expect(read("Hecks")[:items].map { |item| item[:slug] }).to eq(["hecks-item"])
  end

  it "answers unknown for a name no ProjectBoard row holds" do
    expect(read("Nowhere")).to eq(unknown: "no project board is named Nowhere")
  end

  it "answers unknown when the project's checkout names no store" do
    expect(read("Aayss")[:unknown]).to include("no local world")
  end
end
