# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "json"
require "hecks/pipeline_board/adapters/pipeline_web"

# `POST /api/act` over a real socket: each step the page may take runs its launcher command, a
# step that moves code runs only once confirmed, and a request the board refuses never reaches the
# launcher.
RSpec.describe "POST /api/act on the board" do
  let(:sent) { [] }
  let(:refuse) { false }
  let(:app) { Hecks::Adapters::PipelineWeb.new(settings: { stages: stages, background: false, launcher: launcher }) }
  let!(:server) { Hecks::Adapters::PipelineBoard::Server.new(port: 0, app: app).start }

  after { server.stop }

  def stdins = (@stdins ||= [])

  def stages = instance_double(Hecks::Adapters::PipelineStages, state: { stages: [] })

  def launcher
    lambda do |*args, **opts|
      sent << args
      stdins << opts[:stdin]
      raise Hecks::Adapters::PipelineBoard::Unavailable, "launcher refused" if refuse

      ""
    end
  end

  def post(payload, headers = {})
    Net::HTTP.start("127.0.0.1", server.port) do |http|
      http.send_request("POST", "/api/act", JSON.generate(payload), { "Content-Type" => "application/json" }.merge(headers))
    end
  end

  it "answers a blocked session through AgentRun.answer!, with the answer as its text", :aggregate_failures do
    response = post("action" => "answer", "target" => "run-1", "text" => "use staging")
    expect(response.code).to eq("200")
    expect(sent).to eq([["exe/hecks", "AgentRun.answer!", "to=run-1", "answer.value=use staging", "--wait"]])
  end

  it "asks the architect for a review by event, in the checkout the board names", :aggregate_failures do
    response = post("action" => "review", "target" => "w-1", "text" => "build the panel")
    expect(response.code).to eq("200")
    expect(sent.first.first(5)).to eq(["exe/hecks", "agents", "PlanReview.request!", "work.value=w-1", "hops.value=1"])
  end

  it "gives the planner a goal, with a request key and the checkout the board names", :aggregate_failures do
    response = post("action" => "plan", "text" => "plan the agents panel")
    expect(response.code).to eq("200")
    expect(sent.first).to include("agents", "Planning.request!", "goal.value=plan the agents panel", "role.value=planner")
  end

  it "runs a board train once the page confirms it" do
    post("action" => "board_train", "confirm" => true)
    expect(sent).to eq([["exe/hecks", "SendTrain.board!", "--confirm"]])
  end

  it "runs a promotion to stable once the page confirms it" do
    post("action" => "promote", "confirm" => true)
    expect(sent).to eq([["exe/hecks", "PromotionRun.promote!", "lane=stable", "--confirm", "--wait"]])
  end

  it "refuses a push or a promotion that is not confirmed, before the launcher runs", :aggregate_failures do
    response = post("action" => "board_train")
    expect(response.code).to eq("422")
    expect(JSON.parse(response.body)["error"]).to include("runs only with confirm")
    expect(sent).to be_empty
  end

  it "refuses a step that is not on the list", :aggregate_failures do
    expect(post("action" => "release").code).to eq("400")
    expect(sent).to be_empty
  end

  it "refuses a step that is missing a field it needs" do
    response = post("action" => "answer", "target" => "run-1")
    expect(JSON.parse(response.body)["error"]).to include("answer needs text")
  end

  context "when the launcher refuses" do
    let(:refuse) { true }

    it "answers 422 with the launcher's reason" do
      response = post("action" => "answer", "target" => "run-1", "text" => "use staging")
      expect(JSON.parse(response.body)).to include("error" => a_string_including("launcher refused"))
    end
  end

  it "accepts the board's own origin" do
    expect(post({ "action" => "promote", "confirm" => true }, "Origin" => "http://127.0.0.1:#{server.port}").code).to eq("200")
  end

  it "refuses a cross-origin request before the launcher runs", :aggregate_failures do
    response = post({ "action" => "promote", "confirm" => true }, "Origin" => "https://example.com")
    expect(response.code).to eq("403")
    expect(sent).to be_empty
  end

  it "refuses a body that is not JSON" do
    response = Net::HTTP.start("127.0.0.1", server.port) do |http|
      http.send_request("POST", "/api/act", "not json", { "Content-Type" => "application/json" })
    end
    expect(response.code).to eq("400")
  end

  it "serves the page with the act route, not the old answer route", :aggregate_failures do
    page = Net::HTTP.get(URI("http://127.0.0.1:#{server.port}/"))
    expect(page).to include("/api/act")
    expect(page).not_to include("/api/answer")
  end

  context "when a blocked session has no run key and the page replies to it" do
    let(:sessions) do
      [{ id: "s1", status: "blocked", attach: "s1", resume: "resume-uuid", cwd: "/work/session" },
       { id: "s2", status: "done", resume: "other-uuid", cwd: "/work/other" }]
    end

    def stages = instance_double(Hecks::Adapters::PipelineStages, state: { stages: [], sessions: sessions })

    it "resumes the blocked session with the reply, in the session's own directory", :aggregate_failures do
      response = post("action" => "reply", "target" => "s1", "text" => "use staging")
      expect(response.code).to eq("200")
      expect(sent).to eq([["claude", "attach", "s1"]])
      expect(stdins).to eq(["use staging\r"])
    end

    it "refuses a session the board does not report as blocked, before anything runs", :aggregate_failures do
      response = post("action" => "reply", "target" => "s2", "text" => "hi")
      expect(response.code).to eq("422")
      expect(sent).to be_empty
    end
  end
end
