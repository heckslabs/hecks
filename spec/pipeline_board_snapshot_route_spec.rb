# frozen_string_literal: true

require "spec_helper"
require "net/http"
require_relative "support/fake_journal"
require "hecks/pipeline_board/adapters/pipeline_web"

# `GET /api/snapshot` over a real socket: the running board draws the text panel from the state it
# already holds, as `PipelineBoard.snapshot` would, and answers 503 until it holds one.
RSpec.describe Hecks::Adapters::PipelineBoard::SnapshotRoute do
  let(:held) { { stages: [{ name: "CI", state: "ok", count: "0", detail: "green" }] } }
  let(:stages) do
    instance_double(Hecks::Adapters::PipelineStages, state: held, train_prs: [], **FakeJournal::TILES)
  end
  let(:settings) { { stages: stages, background: false, journal: FakeJournal.source, load_guard: false } }
  let!(:server) { Hecks::Adapters::PipelineWeb.new(settings: settings).open_at(0) }

  after { server.stop }

  def get(path) = Net::HTTP.start("127.0.0.1", server.port) { |http| http.get(path) }

  it "answers the panel the snapshot query draws, at the width asked" do
    drawn = Hecks::Adapters::PipelineBoard::Panel.render(held.merge(train_prs: []), width: 100)
    expect(get("/api/snapshot?width=100")).to have_attributes(code: "200", body: drawn)
  end

  it "draws the same text from the held state as the snapshot query does from a fresh read" do
    stages_query = Hecks::Adapters::PipelineStages.allocate
    allow(stages_query).to receive_messages(state: held, train_prs: [])
    expect(get("/api/snapshot?width=90").body).to eq(stages_query.snapshot(width: 90)[:text])
  end

  it "refuses a width that is not a whole number" do
    expect(get("/api/snapshot?width=wide").code).to eq("400")
  end

  it "answers 503 while the board holds no fresh state" do
    board = instance_double(Hecks::Adapters::PipelineWeb, snapshot_panel: nil)
    expect(described_class.answer(board, "width=80").first).to eq(503)
  end

  it "holds no fresh state before a background snapshot's first read" do
    expect(Hecks::Adapters::PipelineBoard::Snapshot.new(source: -> { held }).held?).to be(false)
  end
end
