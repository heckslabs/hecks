require "spec_helper"
require "rack/mock"
require "tmpdir"
require "hecks/composer/web"
require_relative "support/hecks_parse_binary"

# The Composer's Rack app serves the page and the JSON routes it speaks to. Every route is
# exercised here through Rack, with no browser and no network.
RSpec.describe Hecks::Composer::Web, :io do
  include_context "with the hecks-parse binary"

  let(:fixture)   { File.expand_path("fixtures/composer/account", __dir__) }
  let(:workspace) { Dir.mktmpdir("composer-web").tap { |dir| FileUtils.cp_r(Dir.glob("#{fixture}/*"), dir) } }
  let(:request)   { Rack::MockRequest.new(described_class.app(workspace: workspace)) }

  after { FileUtils.rm_rf(workspace) }

  def post(path, payload) = request.post("/composer/#{path}", input: JSON.generate(payload))

  def put(path, payload) = request.put("/composer/#{path}", input: JSON.generate(payload))

  def delete(path, payload) = request.delete("/composer/#{path}", input: JSON.generate(payload))

  def read(response) = JSON.parse(response.body)

  def source = File.read(File.join(workspace, "ledger.bluebook"))

  it "serves the editor page", :aggregate_failures do
    response = request.get("/composer")

    expect(response.status).to eq(200)
    expect(response.content_type).to include("text/html")
    expect(response.body).to include("Hecks Composer")
  end

  it "lists the workspace's declaration files with their text", :aggregate_failures do
    files = read(request.get("/composer/files"))["files"]

    expect(files.map { |file| file["path"] }).to contain_exactly("ledger.bluebook", "ledger.hecksagon")
    expect(files.first["text"]).to include("Hecks.")
  end

  it "answers the parser's verdict on unsaved text with the line and the expected words", :aggregate_failures do
    broken = source.sub("sets :balance", "sett :balance")
    diagnostic = read(post("parse", buffers: { "ledger.bluebook" => broken }))["diagnostic"]

    expect(diagnostic["line"]).to be_a(Integer)
    expect(diagnostic["expected"]).not_to be_empty
  end

  it "answers the whole check, with diagrams and statements", :aggregate_failures do
    result = read(post("check", buffers: {}))

    expect(result["diagnostic"]).to be_nil
    expect(result["diagrams"].keys).to include("Account_lifecycle.mmd")
    expect(result["statements"]).not_to be_empty
  end

  it "saves a domain file inside the workspace", :aggregate_failures do
    response = put("file", path: "ledger.bluebook", text: "Hecks.bluebook \"Ledger\" do\nend\n")

    expect(read(response)).to eq("saved" => "ledger.bluebook")
    expect(source).to include("Hecks.bluebook \"Ledger\"")
  end

  it "refuses to save outside the workspace" do
    expect(put("file", path: "../outside.bluebook", text: "").status).to eq(400)
  end

  it "refuses to save a file that is not a domain file" do
    expect(put("file", path: "notes.txt", text: "").status).to eq(400)
  end

  it "removes a domain file", :aggregate_failures do
    File.write(File.join(workspace, "extra.bluebook"), "")

    expect(delete("file", path: "extra.bluebook").status).to eq(200)
    expect(File).not_to exist(File.join(workspace, "extra.bluebook"))
  end

  it "refuses to remove a file that is not a domain file, or one outside the workspace", :aggregate_failures do
    expect(delete("file", path: "notes.txt").status).to eq(400)
    expect(delete("file", path: "../ledger.bluebook").status).to eq(400)
  end

  it "answers 404 for a route it does not have" do
    expect(request.get("/composer/nothing").status).to eq(404)
  end
end
