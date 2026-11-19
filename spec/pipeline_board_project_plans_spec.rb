# frozen_string_literal: true

require "spec_helper"
require_relative "support/fake_journal"
require "net/http"
require "hecks/pipeline_board/adapters/pipeline_web"

# The planning page of a chosen project: `/plan` is the board's own, `/plan/<name>` another
# `ProjectBoard` row's, drawn once from its own store and only read; each carries the chooser.
RSpec.describe Hecks::Adapters::PipelineBoard::ProjectPlans do
  let(:shorts) do
    Hecks::Adapters::PipelineBoard::PlanReading.build(
      items: [{ slug: "make-a-short", title: "Make a short", status: "planned", epic: "" }], epics: [], sessions: [],
      reviews: [], fill: { would_start: [], skipped: [] }, train: nil, now: Time.now, flow: nil
    )
  end
  let(:stages) do
    instance_double(Hecks::Adapters::PipelineStages, state: { stages: [] }, **FakeJournal::TILES).tap do |double|
      allow(double).to receive(:project_plan_tile).with("Shorts").and_return(shorts)
    end
  end
  let!(:server) { Hecks::Adapters::PipelineWeb.new(settings: { stages: stages, background: false, journal: FakeJournal.source, load_guard: false }).open_at(0) }

  after { server.stop }

  def get(path) = Net::HTTP.start("127.0.0.1", server.port) { |http| http.get(path) }

  it "draws another project's plan, marked as read from its own store" do
    expect(get("/plan/Shorts")).to have_attributes(code: "200", body: include('data-foreign="true"', "make-a-short"))
  end

  it "selects the chosen project in the chooser" do
    expect(get("/plan/Shorts").body).to include('<option value="Shorts" data-href="/plan/Shorts" selected>')
  end

  it "selects the board's own project in the chooser of /plan" do
    expect(get("/plan").body).to include('<option value="Hecks" data-href="/plan" selected>')
  end

  it "answers 404 for a name no ProjectBoard row holds" do
    expect(get("/plan/Nowhere")).to have_attributes(code: "404", body: "no project board is named Nowhere")
  end
end
