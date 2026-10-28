require "spec_helper"
require "rack/mock"
require "tmpdir"
require "hecks/composer/web"
require_relative "support/hecks_parse_binary"

# The routes behind the editor's lower panels, through the real Rack app: the Console and Records
# panels over a booted copy of the workspace, Behaviors, the timeline, Hecks's own commands for the
# palette and Eras, and the one background job.
RSpec.describe "the Composer's lower panels", :io do
  include_context "with the hecks-parse binary"

  let(:workspace) { copy_fixture("account") }
  let(:request)   { Rack::MockRequest.new(Hecks::Composer::Web.app(workspace: workspace)) }

  after { FileUtils.rm_rf(workspace) }

  def copy_fixture(name)
    Dir.mktmpdir("composer-panels").tap do |dir|
      FileUtils.cp_r(Dir.glob("#{File.expand_path("fixtures/composer/#{name}", __dir__)}/*"), dir)
    end
  end

  def post(path, payload = {}) = JSON.parse(request.post("/composer/#{path}", input: JSON.generate(payload)).body)

  def get(path) = JSON.parse(request.get("/composer/#{path}").body)

  def open_account = post("live/dispatch", verb: "Ledger::Account.Open", with: { number: { value: "A1" } })

  def credit(cents)
    amount = { cents: cents, currency: "USD" }
    post("live/dispatch", verb: "Ledger::Account.Credit", to: "A1", with: { amount: amount })
  end

  def ledger_text = File.read(File.join(workspace, "ledger.bluebook"))

  def save(text) = request.put("/composer/file", input: JSON.generate(path: "ledger.bluebook", text: text))

  def settled_job
    1200.times do
      state = get("job")
      return state unless state["status"] == "running"

      Queue.new.pop(timeout: 0.05)
    end
  end

  it "lists the workspace's commands with a starter value for each argument", :aggregate_failures do
    listed = post("live/commands")

    expect(listed["bluebook"]).to eq("Ledger")
    expect(listed["commands"].map { |command| command["verb"] }).to include("Ledger::Account.Open")
  end

  it "dispatches a command against the booted copy and shows the record it made", :aggregate_failures do
    expect(open_account["ok"]).to be(true)
    expect(post("live/records")["records"]["Account"].first["number"]).to eq("A1")
  end

  it "answers a refusal in words, as data", :aggregate_failures do
    open_account
    refused = credit(-5)

    expect(refused["ok"]).to be(false)
    expect(refused["kind"]).to eq("InvariantViolation")
  end

  it "keeps the booted copy between requests, and rebuilds it when the text changes", :aggregate_failures do
    open_account
    same = post("live/records")["records"]["Account"]
    changed = post("live/records", buffers: { "ledger.bluebook" => "#{ledger_text}\n" })

    expect(same.size).to eq(1)
    expect(changed["records"]["Account"]).to be_empty
  end

  it "answers an error, not a crash, when the text does not boot" do
    broken = post("live/commands", buffers: { "ledger.bluebook" => "not a bluebook" })

    expect(broken["error"]).to be_a(String)
  end

  it "keeps each saved file's text in a timeline, newest first", :aggregate_failures do
    2.times { |n| save("Hecks.bluebook \"Ledger\" do\n  # #{n}\nend\n") }
    revisions = post("timeline", path: "ledger.bluebook")["revisions"]

    expect(revisions.size).to eq(2)
    expect(revisions.first["text"]).to include("# 1")
  end

  it "lists Hecks's commands and queries, marking the ones that change things as guarded", :aggregate_failures do
    catalog = get("catalog")["catalog"]

    expect(catalog.find { |row| row["verb"] == "introspection.shape" }).to include("kind" => "query", "guarded" => false)
    expect(catalog.any? { |row| row["guarded"] }).to be(true)
  end

  it "refuses a guarded command that was not confirmed, and runs a query on the workspace", :aggregate_failures do
    guarded = get("catalog")["catalog"].find { |row| row["guarded"] }
    refused = post("run", kind: guarded["kind"], verb: guarded["verb"], args: {})
    shape = post("run", kind: "query", verb: "introspection.shape", args: { "domain.value" => "$WORKSPACE" })

    expect(refused["ok"]).to be(false)
    expect(shape["output"]).to start_with("Ledger")
  end

  it "reads the era queries over the workspace", :aggregate_failures do
    eras = get("eras")

    expect(eras.keys).to contain_exactly("shape", "scaffold_translation", "audit_translation", "compaction")
    expect(eras["shape"]["output"]).to start_with("Ledger")
  end

  it "runs a job in the background and reports its end", :aggregate_failures do
    started = post("job", kind: "query", verb: "introspection.shape", args: { "domain.value" => "$WORKSPACE" })
    state = settled_job

    expect(started["started"]).to be(true)
    expect(state).to include("status" => "done", "ok" => true)
  end

  describe "behaviors" do
    let(:workspace) { copy_fixture("behaviors") }

    it "runs the workspace's behaviors, with unsaved text laid over the files", :aggregate_failures do
      result = post("behaviors")

      expect(result["files"].first["path"]).to eq("ledger.behaviors")
      expect(result["summary"]["failed"]).to eq(0)
    end
  end
end
