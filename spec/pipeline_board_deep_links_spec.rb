# frozen_string_literal: true

require "spec_helper"
require_relative "support/fake_journal"
require "net/http"
require_relative "support/pipeline_board_world"
require "hecks/pipeline_board/adapters/pipeline_web"

# The board's per-item URLs over a real socket on an ephemeral port: `/runs/<run>` for an AgentRun
# and `/trains/<run>` for a SendTrain boarding: the first answers the board page, which highlights
# the run's row in place, the second the Events page, which opens with its search on the boarding;
# under `/api` each answers the item as JSON, for tools.
RSpec.describe Hecks::Adapters::PipelineBoard::DeepLinks do
  let(:run) do
    { run: "r-1", work: "w-1", agent: "coder", status: "finished", condition: "done", session: "abc123", repo: "/repo",
      refusal: "", brief: "do <the> thing", detail: "all landed", landed: ["f" * 40],
      commits: [{ sha: "f" * 9, url: "https://github.com/o/r/commit/#{"f" * 40}", ci_url: "https://github.com/o/r/actions/runs/9" }] }
  end
  let(:train) do
    { run: "t-1", status: "queued", boarded: "e" * 40, pushed: "", report: "queued", outcome: "queued",
      pr: { number: 12, url: "https://github.com/o/r/pull/12", state: "open", merge: nil,
            checks: [{ name: "rspec", result: "SUCCESS", url: "https://github.com/o/r/actions/runs/5" }] } }
  end
  let(:stages) do
    instance_double(Hecks::Adapters::PipelineStages, state: { stages: [] }, **FakeJournal::TILES).tap do |double|
      allow(double).to receive(:run_detail) { |key| ["r-1", "abc123"].include?(key) ? run : nil }
      allow(double).to receive(:train_detail) { |key| key == "t-1" ? train : nil }
    end
  end
  let!(:server) { Hecks::Adapters::PipelineWeb.new(settings: { stages: stages, background: false, journal: FakeJournal.source }).open_at(0) }

  after { server.stop }

  def get(path) = Net::HTTP.start("127.0.0.1", server.port) { |http| http.get(path) }

  def json(path) = JSON.parse(get(path).body)

  def page = File.read(Hecks::Adapters::PipelineWeb::PAGE)

  it "answers a run's link with the board page, which highlights the run's row" do
    expect(get("/runs/r-1")).to have_attributes(code: "200", body: include("Pipeline Board", "highlight-banner"))
  end

  it "answers a boarding's link with the Events page, not the board" do
    expect(get("/trains/t-1").body.force_encoding("UTF-8")).to eq(get("/events").body.force_encoding("UTF-8"))
  end

  it "marks the Events page as the current one in the bar for a boarding's link" do
    expect(get("/trains/t-1").body).to include("data-also=\"/trains/\"")
  end

  it "opens the Events page with its search on the boarding, after the events are read" do
    expect(events_page).to include("take(j.events, false); openOnBoarding(); draw();", "find(decodeURIComponent(m[1]))")
  end

  it "answers the board page for a run no one has, and the page says so in its banner" do
    expect(get("/runs/nope")).to have_attributes(code: "200", body: include("is not on the board"))
  end

  def events_page = File.read(Hecks::Adapters::PipelineBoard::EventsPage::PATH)

  it "links every session row to its deep link, on the board itself" do
    expect(page).to include("\"/runs/\" + encodeURIComponent(s.run || s.id)")
  end

  it "has no Events panel and nothing that draws one" do
    expect(page).not_to match(%r{id="feed"|putEvent|renderEvents|trainLabel|chainOf|eventTip|\.feed\b|\.ev\b|a\[href\^='/trains/})
  end

  it "links an event's boarding from the Events page to its deep link" do
    expect(events_page).to include("href: \"/trains/\" + encodeURIComponent(ev.id)", "this boarding")
  end

  it "intercepts a click on an in-board run link instead of leaving the page" do
    expect(page).to include("a[href^='/runs/']", "e.preventDefault(); setHighlight(next, \"push\")")
  end

  it "keeps the ring while the link stands and clears it on a click elsewhere" do
    expect(page).to include("history.pushState(null, \"\", path)", "setHighlight(null, \"replace\")")
  end

  def agents_page = File.read(Hecks::Adapters::PipelineWeb::AGENTS_PAGE)

  it "sends the Agents page's session links to the board as well" do
    expect(agents_page).to include("href: \"/runs/\" + encodeURIComponent(w.run || w.id)", "Highlight this run on the board")
  end

  it "answers a run's JSON under /api" do
    expect(json("/api/runs/r-1")).to include("run" => "r-1", "status" => "finished", "session" => "abc123")
  end

  it "finds a run's JSON by its session id too" do
    expect(get("/api/runs/abc123").code).to eq("200")
  end

  it "answers 404 JSON for a run no one has" do
    expect(get("/api/runs/nope").code).to eq("404")
  end

  it "answers a boarding's JSON under /api, with its pull request" do
    expect(json("/api/trains/t-1")["pr"]).to include("number" => 12, "state" => "open")
  end

  it "answers 404 JSON for a boarding no one has" do
    expect(get("/api/trains/none").code).to eq("404")
  end

  it "refuses a key that is not plain" do
    expect(get("/runs/..%2Fetc").code).to eq("404")
  end

  it "answers 503 with the reason when the run records cannot be read" do
    allow(stages).to receive(:run_detail).and_raise(Hecks::Adapters::PipelineBoard::Unavailable, "no store")
    expect([get("/api/runs/r-1").code, get("/api/runs/r-1").body]).to eq(["503", "no store"])
  end
end
