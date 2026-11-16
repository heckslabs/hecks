# frozen_string_literal: true

require "spec_helper"
require "rack/test"
require "net/http"
require "tmpdir"
require "hecks/hecks/adapters/github_listening"

# The webhook listener takes `POST /github-webhook` signed with the secret file's secret and records
# each delivery of a followed kind once, through `GithubEvent.Record`, in Memory here. Payloads are
# trimmed from GitHub's documented shapes.
RSpec.describe Hecks::Adapters::GithubListening do
  include Rack::Test::Methods

  before(:all) { @hecks = boot_hecks_in_memory }

  let(:folder) { Dir.mktmpdir("github-listening") }
  let(:secret_path) { File.join(folder, "secret").tap { |path| File.write(path, "listening-spec-secret\n") } }
  let(:listening) { described_class.new(registry: @hecks.registry, settings: { secret_path: secret_path }) }
  let(:app) { listening.receiver }

  after { FileUtils.rm_rf(folder) }

  def check_run
    { "action" => "completed", "check_run" => {
      "id" => 4, "name" => "rspec", "head_sha" => "ce587453ced02b1526dfb4cb910479d431683101", "status" => "completed",
      "conclusion" => "success", "check_suite" => { "head_branch" => "feature-x" },
      "pull_requests" => [{ "number" => 12 }]
    } }
  end

  def merged_pull_request
    { "action" => "closed", "number" => 31,
      "pull_request" => { "number" => 31, "state" => "closed", "merged" => true,
                          "head" => { "ref" => "train/main-abc", "sha" => "abc1234" } } }
  end

  def workflow_run
    { "action" => "completed", "workflow_run" => { "id" => 30_433_642, "name" => "CI", "head_branch" => "main",
                                                   "head_sha" => "acb5820ced9479c074f688cc328bf03f341a511d",
                                                   "status" => "completed", "conclusion" => "failure",
                                                   "pull_requests" => [] } }
  end

  def deliver(event, payload, delivery:, secret: "listening-spec-secret", path: "/github-webhook")
    body = JSON.generate(payload)
    signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, body)}"
    post path, body, "HTTP_X_HUB_SIGNATURE_256" => signature, "HTTP_X_GITHUB_EVENT" => event,
                     "HTTP_X_GITHUB_DELIVERY" => delivery
  end

  def recorded(delivery)
    Hecks::Runtime::Dispatcher.new(@hecks.registry).query("Hecks::GithubEvent.Since", cursor: 0)
                              .map { |row| row.to_h.transform_values { |value| value.respond_to?(:value) ? value.value : value } }
                              .select { |row| row[:delivery] == delivery }
  end

  it "answers a signed check_run 202 and records its facts once", :aggregate_failures do
    deliver("check_run", check_run, delivery: "cr-1")
    expect(last_response.status).to eq(202)
    expect(recorded("cr-1").first).to include(kind: "check_run", action: "completed", pr: 12, check: "rspec",
                                              commit: "ce587453ced02b1526dfb4cb910479d431683101",
                                              branch: "feature-x", conclusion: "success")
  end

  it "records a merged pull request as merged, with its head" do
    deliver("pull_request", merged_pull_request, delivery: "pr-1")
    expect(recorded("pr-1").first).to include(pr: 31, conclusion: "merged", branch: "train/main-abc", commit: "abc1234")
  end

  it "records a completed workflow run with its run id and name" do
    deliver("workflow_run", workflow_run, delivery: "wr-1")
    expect(recorded("wr-1").first).to include(ci_run: "30433642", check: "CI", conclusion: "failure", branch: "main")
  end

  it "keeps a delivery sent again once", :aggregate_failures do
    2.times { deliver("check_run", check_run, delivery: "cr-again") }
    expect(last_response.status).to eq(202)
    expect(recorded("cr-again").size).to eq(1)
  end

  it "answers a wrong signature 401 and records nothing", :aggregate_failures do
    deliver("check_run", check_run, delivery: "cr-forged", secret: "another-secret")
    expect(last_response.status).to eq(401)
    expect(recorded("cr-forged")).to be_empty
  end

  it "answers a kind the pipeline does not follow 202 and records nothing", :aggregate_failures do
    deliver("push", { "ref" => "refs/heads/main" }, delivery: "push-1")
    expect(last_response.status).to eq(202)
    expect(recorded("push-1")).to be_empty
  end

  it "answers a body over one megabyte 413" do
    deliver("check_run", { "pad" => "x" * 1_100_000 }, delivery: "big-1")
    expect(last_response.status).to eq(413)
  end

  it "answers any other path 404 and a GET of the path 405", :aggregate_failures do
    deliver("check_run", check_run, delivery: "cr-elsewhere", path: "/")
    expect(last_response.status).to eq(404)
    get "/github-webhook"
    expect(last_response.status).to eq(405)
  end

  it "refuses to start, naming the file, when the secret file is absent" do
    absent = described_class.new(registry: @hecks.registry, settings: { secret_path: File.join(folder, "none") })
    expect { absent.open_at(0) }.to raise_error(described_class::SecretFile::Missing, /none/)
  end

  # Starts the listener on a free port, hands it to the block and stops it.
  def serving
    server = listening.open_at(0)
    thread = Thread.new { server.start }
    yield server
  ensure
    server&.shutdown
    thread&.join(5)
  end

  it "binds 127.0.0.1 only and answers there", :aggregate_failures do
    serving do |server|
      expect(server.config[:BindAddress]).to eq("127.0.0.1")
      expect(Net::HTTP.get_response(URI("http://127.0.0.1:#{server.config[:Port]}/elsewhere")).code).to eq("404")
    end
  end
end
