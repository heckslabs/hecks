require "spec_helper"
require "rack/test"
require "openssl"
require "json"
require_relative "../../qa/adapters/github_ci_webhook"

# THE PUSH SIBLING OF spec/adapters/github_checks_spec.rb — that file
# proves the PULL adapter's own transport (stubbing `Open3.capture3`
# rather than shelling to a real `gh`); this proves the PUSH adapter's
# own transport (a signed, realistic HTTP request, posted straight at
# `#call(env)`, rather than a real internet-facing endpoint GitHub could
# reach — the same "cannot stand up a real endpoint in this sandbox, so
# test the Rack app directly" trade this whole suite already makes for
# `Hecks::Forms::App` in spec/forms/app_spec.rb).
#
# END TO END, FOR REAL, AGAINST THE ACTUAL DOMAIN — not a mock of
# `QualityControl`. A real `Target`/`Sweep`/`Bug` is logged and fixed
# with a real commit exactly the way `spec/quality_control_spec.rb`'s own
# "the CI watch" examples do; the ONLY thing synthetic here is the
# webhook delivery itself (this sandbox cannot make GitHub send a real
# one) — the payload shape, the signature, and the HTTP request all run
# for real, and so does everything downstream of them: `Clearance`
# settling, and `BugCiWatch` reacting to it.
RSpec.describe "GitHub CI webhook, end to end" do
  include Rack::Test::Methods

  SECRET = "test-webhook-secret-do-not-use-in-real-life".freeze

  QC_ROOT = File.join(InMemoryDomain::ROOT, "qa/bluebook").freeze

  module FixedClock
    module_function

    def now = 1_000
  end

  # NEITHER TRACKER NOR CI ADAPTER IS EXERCISED BY THIS SPEC — the
  # webhook settles a `Clearance` directly (see
  # `Hecks::QA::ClearanceRecorder`), never asking the `CI` port at all.
  # Both are still bound because `registry.verify!` below refuses to
  # boot with an unbound port, the same reason
  # `spec/quality_control_spec.rb`'s own boot binds them.
  def bind_stub_adapters!
    stub_tracker = Class.new { def file(**) = {} }
    stub_ci      = Class.new { def run(**) = raise "never asked — the webhook settles directly" }

    stub_const("Hecks::Adapters::WebhookSpecTracker", stub_tracker)
    Hecks.adapter("WebhookSpecTracker") { port "IssueTracker" }

    stub_const("Hecks::Adapters::WebhookSpecCi", stub_ci)
    Hecks.adapter("WebhookSpecCi") { port "CI" }

    stub_const("Hecks::Adapters::WebhookSpecClock", FixedClock)
    Hecks.adapter("WebhookSpecClock") { port "clock" }
  end

  def boot_quality_control
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(QC_ROOT, "quality_control.bluebook"))
      bind_stub_adapters!

      Hecks.hecksagon "QualityControl" do
        uses_framework "Governance"

        QualityControl::Target.persisted_by("Memory")
        QualityControl::Sweep.persisted_by("Memory")
        QualityControl::Bug.persisted_by("Memory")
        QualityControl::Angle.persisted_by("Memory")
        QualityControl::Ticket.persisted_by("Memory")
        QualityControl::Clearance.persisted_by("Memory")

        QualityControl::Ticket.port "IssueTracker" do
          asks "File", to: Ticket do
            answers "IssueFiled"
            refuses "IssueFilingRefused"
          end
          tells "Closed", to: Ticket do
            emits "IssueClosedUpstream"
          end
        end

        QualityControl::Clearance.port "CI" do
          asks "Run", to: Clearance do
            answers "SuitePassed"
            refuses "SuiteFailed"
          end
        end
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let!(:runtime) { boot_quality_control }

  def app
    @app ||= Hecks::Adapters::Driving::GithubCiWebhook.new(secret: SECRET)
  end

  def a_target(reference: "banking", path: "examples/banking")
    QualityControl::Target.identify!(reference: { value: reference }, path: { value: path })
  end

  def a_sweep(target, reference: "SW-1")
    QualityControl::Sweep.open!(target: target.id, reference: { value: reference }, engineer: { value: "Claude QA" })
  end

  def a_fixed_bug(sweep, commit, reference: "BUG#1", sequence: 1)
    bug = QualityControl::Bug.log!(
      sweep: sweep.id,
      reference: { value: reference }, sequence: { value: sequence },
      title: { value: "as: is accepted and does not alias" },
      demonstration: { value: 'rspec spec/qa_bugs_spec.rb -e "aliasing"' },
      symptom: { value: "the alias is ignored" }, expectation: { value: "the alias answers" },
      submitter: { value: "Claude QA" }
    )
    bug.investigate!(site: { value: "lib/x.rb:1" }, cause: { value: "y" })
    bug.fix!(reference: { value: reference }, commit: { value: commit })
  end

  # A REAL `check_suite` PAYLOAD SHAPE — trimmed to the fields this
  # adapter (or a human reading a fixture) would actually look at, but
  # every field present is a real field GitHub's own webhook payload
  # documentation for `check_suite` describes, not an invented one:
  # `action`, `check_suite.id`, `check_suite.head_sha`,
  # `check_suite.status`, `check_suite.conclusion`, `check_suite.
  # head_branch`, `check_suite.app`, plus the `repository`/`sender`
  # envelope every GitHub webhook delivery carries regardless of event
  # type.
  def check_suite_payload(sha, conclusion:, action: "completed", status: "completed")
    {
      "action"      => action,
      "check_suite" => {
        "id"                      => 118_578_147,
        "head_branch"             => "loop-parity/example",
        "head_sha"                => sha,
        "status"                  => status,
        "conclusion"              => conclusion,
        "url"                     => "https://api.github.com/repos/octocat/hecks/check-suites/118578147",
        "before"                  => "0" * 40,
        "after"                   => sha,
        "pull_requests"           => [],
        "app"                     => { "id" => 15_368, "slug" => "github-actions", "name" => "GitHub Actions" },
        "created_at"              => "2026-09-10T00:00:00Z",
        "updated_at"              => "2026-09-10T00:05:00Z",
        "latest_check_runs_count" => 3,
        "check_runs_url"          => "https://api.github.com/repos/octocat/hecks/commits/#{sha}/check-runs",
        "head_commit"             => {
          "id" => sha, "tree_id" => "f" * 40, "message" => "qa: example commit",
          "timestamp" => "2026-09-10T00:00:00Z",
          "author" => { "name" => "Miette", "email" => "miette@embryonaut.ai" },
          "committer" => { "name" => "Miette", "email" => "miette@embryonaut.ai" }
        }
      },
      "repository"  => { "id" => 1_296_269, "name" => "hecks", "full_name" => "octocat/hecks" },
      "sender"      => { "login" => "octocat", "id" => 1 }
    }
  end

  def sign(body) = "sha256=#{OpenSSL::HMAC.hexdigest('sha256', SECRET, body)}"

  def post_webhook(payload, event: "check_suite", signature: nil, event_header: true)
    body = JSON.generate(payload)
    headers = { "CONTENT_TYPE" => "application/json" }
    headers["HTTP_X_HUB_SIGNATURE_256"] = signature || sign(body)
    headers["HTTP_X_GITHUB_EVENT"] = event if event_header
    post "/", body, headers
  end

  # ── the domain actually reacting to a real delivery ───────────────────

  describe "a completed check_suite that passed" do
    it "settles the exact commit green, and never touches the bug" do
      bug = a_fixed_bug(a_sweep(a_target), "e1dd034bd8340fc53aa931933cb6587288698f5")

      post_webhook(check_suite_payload(bug.commit.to_h[:value], conclusion: "success"))

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["ok"]).to be(true)
      expect(body["status"]).to eq("green")

      expect(runtime.query("QualityControl::Clearance.For", commit: { value: bug.commit.to_h[:value] }).length).to eq(1)
      expect(QualityControl::Bug.find("BUG#1").status).to eq("fixed")
    end
  end

  describe "a completed check_suite that failed" do
    it "settles the commit red and lets BugCiWatch put the bug back, for real" do
      a_fixed_bug(a_sweep(a_target), "4f2a19c8340fc53aa931933cb6587288698f51d")

      post_webhook(check_suite_payload("4f2a19c8340fc53aa931933cb6587288698f51d", conclusion: "failure"))

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["status"]).to eq("red")

      expect(runtime.query("QualityControl::Clearance.Red").first[:commit][:value])
        .to eq("4f2a19c8340fc53aa931933cb6587288698f51d")
      expect(QualityControl::Bug.find("BUG#1").status).to eq("investigating")
      expect(runtime.sagas).to include(hash_including(process_manager: "BugCiWatch", dispatch: "Bug.Regress", delivered: true))
    end
  end

  # A CONCLUSION THIS ADAPTER DOES NOT SPECIAL-CASE — GitHub's own
  # `conclusion` enum has more members than "success" and "failure"
  # (`neutral`, `skipped`, `cancelled`, `timed_out`, `action_required`,
  # `stale`). Handled the same way `Hecks::Adapters::GithubChecks::
  # PASSING` already handles them for a single check-run: `neutral`/
  # `skipped` count as green (GitHub's own words for "ran, and chose not
  # to fail the commit"); anything else — `cancelled` here — is treated
  # as NOT cleared, failing safe rather than silently reading an
  # ambiguous verdict as passing.
  describe "a conclusion outside plain success/failure" do
    it "treats neutral as cleared, the same as a passing check-run would be" do
      a_fixed_bug(a_sweep(a_target), "1111111")

      post_webhook(check_suite_payload("1111111", conclusion: "neutral"))

      expect(JSON.parse(last_response.body)["status"]).to eq("green")
    end

    it "treats cancelled as NOT cleared, failing safe rather than guessing" do
      a_fixed_bug(a_sweep(a_target), "2222222")

      post_webhook(check_suite_payload("2222222", conclusion: "cancelled"))

      expect(JSON.parse(last_response.body)["status"]).to eq("red")
    end
  end

  # ── refusals ────────────────────────────────────────────────────────

  describe "a badly-signed payload" do
    it "is refused, loudly, and dispatches nothing" do
      payload = check_suite_payload("3333333", conclusion: "success")

      post_webhook(payload, signature: "sha256=0000000000000000000000000000000000000000000000000000000000000000")

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]).to eq("InvalidSignature")
      expect(runtime.query("QualityControl::Clearance.All")).to be_empty
    end

    it "is refused when there is no signature header at all" do
      body = JSON.generate(check_suite_payload("4444444", conclusion: "success"))
      post "/", body, { "CONTENT_TYPE" => "application/json", "HTTP_X_GITHUB_EVENT" => "check_suite" }

      expect(last_response.status).to eq(401)
      expect(runtime.query("QualityControl::Clearance.All")).to be_empty
    end
  end

  describe "a payload that does not even parse as JSON" do
    it "answers 400, distinct from a signature refusal" do
      body = "not json at all"
      post "/", body, { "CONTENT_TYPE" => "application/json",
                        "HTTP_X_HUB_SIGNATURE_256" => sign(body), "HTTP_X_GITHUB_EVENT" => "check_suite" }

      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body)["error"]).to eq("MalformedPayload")
    end
  end

  describe "a commit that does not look like a sha" do
    it "refuses rather than settle a clearance nobody could ever look up" do
      payload = check_suite_payload("not-a-sha", conclusion: "success")

      post_webhook(payload)

      expect(last_response.status).to eq(422)
      expect(JSON.parse(last_response.body)["error"]).to eq("MalformedCommit")
    end
  end

  describe "GitHub's own connectivity check" do
    it "answers ping without touching the domain at all" do
      body = JSON.generate({ "zen" => "Design for failure." })
      post "/", body, { "CONTENT_TYPE" => "application/json",
                        "HTTP_X_HUB_SIGNATURE_256" => sign(body), "HTTP_X_GITHUB_EVENT" => "ping" }

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("ok" => true, "event" => "ping")
    end
  end

  describe "an event this adapter does not act on" do
    it "acknowledges a check_run event without settling anything — it is not the whole suite" do
      payload = { "action" => "completed", "check_run" => { "head_sha" => "5555555", "conclusion" => "success" } }
      body = JSON.generate(payload)
      post "/", body, { "CONTENT_TYPE" => "application/json",
                        "HTTP_X_HUB_SIGNATURE_256" => sign(body), "HTTP_X_GITHUB_EVENT" => "check_run" }

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["ignored"]).to include("not a check_suite event")
      expect(runtime.query("QualityControl::Clearance.All")).to be_empty
    end

    it "acknowledges a check_suite still in progress without settling anything" do
      payload = check_suite_payload("6666666", conclusion: nil, action: "requested", status: "in_progress")

      post_webhook(payload)

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["ignored"]).to include("not yet completed")
      expect(runtime.query("QualityControl::Clearance.All")).to be_empty
    end
  end

  describe "GET, or anything but POST" do
    it "answers 405" do
      get "/"

      expect(last_response.status).to eq(405)
    end
  end

  # ── idempotency — GitHub redelivers ────────────────────────────────

  describe "the same delivery arriving twice" do
    it "settles once and answers the same way the second time, rather than raising" do
      a_fixed_bug(a_sweep(a_target), "7777777")
      payload = check_suite_payload("7777777", conclusion: "success")

      post_webhook(payload)
      first_status = last_response.status

      post_webhook(payload)

      expect(first_status).to eq(200)
      expect(last_response.status).to eq(200)
      expect(runtime.query("QualityControl::Clearance.All").length).to eq(1)
    end
  end

  # THE GENERIC BASE, ON ITS OWN — the mechanism `GithubCiWebhook` above
  # inherits (signature verification, ping, JSON parsing) covered
  # directly against the abstract class, so a future second driving
  # adapter reusing it has evidence the base itself works independent
  # of anything QualityControl-specific. Nested here rather than a
  # second top-level `RSpec.describe`, purely to keep one example group
  # per file (RSpec/MultipleDescribes) — `described_class` still
  # resolves to `GithubWebhook` inside this block, not the outer
  # string-described group.
  describe Hecks::Adapters::Driving::GithubWebhook do
    it "refuses to be constructed with no secret at all" do
      expect { described_class.new(secret: "") }.to raise_error(ArgumentError, /no webhook secret/)
      expect { described_class.new(secret: nil) }.to raise_error(ArgumentError, /no webhook secret/)
    end

    it "refuses a subclass that never implements handle_event" do
      app = described_class.new(secret: "s")
      body = JSON.generate({ "action" => "completed" })
      signature = "sha256=#{OpenSSL::HMAC.hexdigest('sha256', 's', body)}"
      env = Rack::MockRequest.env_for("/", method: "POST", input: body,
                                      "CONTENT_TYPE" => "application/json",
                                      "HTTP_X_HUB_SIGNATURE_256" => signature,
                                      "HTTP_X_GITHUB_EVENT" => "check_suite")

      expect { app.call(env) }.to raise_error(NotImplementedError, /must implement #handle_event/)
    end
  end
end
