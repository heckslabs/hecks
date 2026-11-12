# frozen_string_literal: true

require "spec_helper"
require_relative "support/fake_journal"
require "net/http"
require "hecks/pipeline_board/adapters/pipeline_web"

# The planning page is served at /plan, linked from the board and drawn from the pushed plan tile.
RSpec.describe "the planning page route" do
  let(:stages) do
    instance_double(Hecks::Adapters::PipelineStages, state: { stages: [] }, **FakeJournal::TILES)
  end
  let!(:server) { Hecks::Adapters::PipelineWeb.new(settings: { stages: stages, background: false, journal: FakeJournal.source }).open_at(0) }

  after { server.stop }

  def get(path) = Net::HTTP.start("127.0.0.1", server.port) { |http| http.get(path) }

  it "serves /plan with the plan tile drawn in" do
    expect(get("/plan")).to have_attributes(code: "200", body: include("Planning", "unknown: none"))
  end

  it "links the planning page from the board's header" do
    expect(get("/").body).to include('href="/plan"')
  end

  it "no longer draws the plan reviews list on the Agents page" do
    expect(get("/agents").body).not_to include("renderReviews")
  end

  it "keeps the form that asks the architect for a review on the Agents page" do
    expect(get("/agents").body).to include("Ask the architect to review a plan")
  end
end
