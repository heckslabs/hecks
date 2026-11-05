# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "json"
require "hecks/pipeline_board/adapters/pipeline_web"

# `POST /api/answer` over a real socket: a blocked session's answer goes to `AgentRun.answer!`
# through the launcher, and the requests the board refuses never reach it.
RSpec.describe "POST /api/answer on the board" do
  let(:sent) { [] }
  let(:refuse) { false }
  let(:app) { Hecks::Adapters::PipelineWeb.new(settings: { stages: stages, background: false, answerer: answerer }) }
  let!(:server) { Hecks::Adapters::PipelineBoard::Server.new(port: 0, app: app).start }

  after { server.stop }

  def stages = instance_double(Hecks::Adapters::PipelineStages, state: { stages: [] })

  def body = { "run" => "run-1", "answer" => "use staging" }

  def answerer
    lambda do |*args|
      sent << args
      raise Hecks::Adapters::PipelineBoard::Unavailable, "AgentRun.answer! refused: not blocked on a person" if refuse

      ""
    end
  end

  def post(payload, headers = {})
    Net::HTTP.start("127.0.0.1", server.port) do |http|
      http.send_request("POST", "/api/answer", JSON.generate(payload), { "Content-Type" => "application/json" }.merge(headers))
    end
  end

  it "runs AgentRun.answer! for the run, with the answer as its text", :aggregate_failures do
    expect(post(body).code).to eq("200")
    expect(sent).to eq([["exe/hecks", "AgentRun.answer!", "to=run-1", "answer.value=use staging", "--wait"]])
  end

  it "answers answered: true once the command has run" do
    expect(JSON.parse(post(body).body)).to eq("answered" => true)
  end

  it "accepts the board's own origin" do
    expect(post(body, "Origin" => "http://127.0.0.1:#{server.port}").code).to eq("200")
  end

  context "when the command refuses" do
    let(:refuse) { true }

    it "answers 422 with the command's reason and says nothing was sent past it", :aggregate_failures do
      response = post(body)
      expect(response.code).to eq("422")
      expect(JSON.parse(response.body)["error"]).to include("not blocked on a person")
    end
  end

  it "refuses a cross-origin request before the command runs", :aggregate_failures do
    expect(post(body, "Origin" => "http://evil.example").code).to eq("403")
    expect(sent).to be_empty
  end

  it "refuses a form post, which the board does not take", :aggregate_failures do
    expect(post(body, "Content-Type" => "text/plain").code).to eq("415")
    expect(sent).to be_empty
  end

  it "refuses a body without a run and an answer", :aggregate_failures do
    expect(post({ "run" => "run-1" }).code).to eq("400")
    expect(sent).to be_empty
  end

  it "serves a page whose answer prompt posts to /api/answer" do
    page = Net::HTTP.start("127.0.0.1", server.port) { |http| http.get("/") }.body
    expect(page).to include('<dialog id="answer"', "fetch(\"/api/answer\"")
  end

  it "answers 405 to a POST to any other route" do
    expect(Net::HTTP.start("127.0.0.1", server.port) { |http| http.send_request("POST", "/api/state", "{}") }.code).to eq("405")
  end
end
