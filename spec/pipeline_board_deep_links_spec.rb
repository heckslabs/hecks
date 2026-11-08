# frozen_string_literal: true

require "spec_helper"
require "net/http"
require_relative "support/pipeline_board_world"
require "hecks/pipeline_board/adapters/pipeline_web"

# The board's per-item URLs over a real socket on an ephemeral port: `/runs/<run>` for an AgentRun,
# `/trains/<run>` for a SendTrain boarding, each as a page and as JSON under `/api`.
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
    instance_double(Hecks::Adapters::PipelineStages, state: { stages: [] }).tap do |double|
      allow(double).to receive(:run_detail) { |key| ["r-1", "abc123"].include?(key) ? run : nil }
      allow(double).to receive(:train_detail) { |key| key == "t-1" ? train : nil }
    end
  end
  let!(:server) { Hecks::Adapters::PipelineWeb.new(settings: { stages: stages, background: false }).open_at(0) }

  after { server.stop }

  def get(path) = Net::HTTP.start("127.0.0.1", server.port) { |http| http.get(path) }

  def json(path) = JSON.parse(get(path).body)

  it "serves a run's page with its brief, role, detail and landed commit" do
    expect(get("/runs/r-1").body).to include("coder", "all landed", "do &lt;the&gt; thing", "/commit/#{"f" * 40}")
  end

  it "links the CI run of a landed commit" do
    expect(get("/runs/r-1").body).to include("https://github.com/o/r/actions/runs/9")
  end

  it "finds a run by its session id too" do
    expect(get("/runs/abc123").code).to eq("200")
  end

  it "answers a run's JSON under /api" do
    expect(json("/api/runs/r-1")).to include("run" => "r-1", "status" => "finished", "session" => "abc123")
  end

  it "answers 404 for a run no one has" do
    expect(get("/runs/nope").code).to eq("404")
  end

  it "serves a boarding's page with its pull request, checks and outcome" do
    expect(get("/trains/t-1").body).to include("#12 (open)", "pull/12", "rspec", "queued")
  end

  it "answers a boarding's JSON under /api" do
    expect(json("/api/trains/t-1")["pr"]).to include("number" => 12, "state" => "open")
  end

  it "answers 404 for a boarding no one has" do
    expect(get("/api/trains/none").code).to eq("404")
  end

  it "refuses a key that is not plain" do
    expect(get("/runs/..%2Fetc").code).to eq("404")
  end

  it "answers 503 with the reason when the run records cannot be read" do
    allow(stages).to receive(:run_detail).and_raise(Hecks::Adapters::PipelineBoard::Unavailable, "no store")
    expect([get("/runs/r-1").code, get("/runs/r-1").body]).to eq(["503", "no store"])
  end

  it "escapes a link that is not a web address" do
    expect(described_class.link("javascript:alert(1)", "x")).to eq("x")
  end
end
