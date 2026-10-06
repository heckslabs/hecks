require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "support/box_hosting_stubs"

# `hecks deploy service_roll.run` and `box_roll.run` end to end: the Deploy chapter's ServiceRoll
# and BoxRoll ask the DeployToolchain port, the Hecks domain binds its adapter, and the generated
# `deploy-service.sh` and `deploy-box.sh` (the golden files) run against stand-in `aws`, `docker`
# and `gh` programs. A successful roll's policy requests a SmokeRun. Nothing reaches AWS or GitHub.
RSpec.describe "the Deploy chapter's ServiceRoll and BoxRoll", :io do
  ROLL_TAGS = "tags=website=website-old cms=cms-old".freeze
  PLATFORM_TAGS = { "website" => "website-old", "cms" => "cms-old", "domain" => "domain-old" }.freeze
  PARAMETERS = { "WebsiteImageTag" => "website-old", "CmsImageTag" => "cms-keep",
                 "EngineImageTag" => "domain-old", "Other" => "x" }.freeze
  VERIFIED_STATE = { "status" => "verified", "tag" => "cms-old", "taskdef" => "widget-platform:7" }.freeze
  REDEPLOY_ENV = { "STUB_ECR_HAS_TAG" => "1", "STUB_NO_UPDATES" => "1" }.freeze
  ROLL_NO_DATABASE_ENV = { "FAKE_NO_DATABASE" => "1", "EXISTING_TAG" => "cms-old", "STUB_ECR_HAS_TAG" => "1" }.freeze

  let(:taskdef_golden)  { File.join(__dir__, "fixtures", "deploy_box_golden", "hosting_taskdef") }
  let(:services_golden) { File.join(__dir__, "fixtures", "deploy_box_golden", "hosting_services") }
  let(:registry)        { BoxHostingStubs::REGISTRY }

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
  end

  # Runs each example of the group with a stand-in toolchain built from the golden named by the `let`.
  def self.with_stub_runner(golden, **options)
    around do |example|
      BoxHostingStubs.with_runner(send(golden), **options) do |runner|
        @runner = runner
        example.run
      end
    end
  end

  attr_reader :runner

  # The stand-in programs first on PATH, as the generated scripts find them.
  def stub_env(env = {})
    { "PATH" => "#{File.join(runner.dir, "bin")}:#{ENV.fetch("PATH")}", "STUB_DIR" => runner.dir,
      "SETTLE_CHECK_INTERVAL_SECS" => "1", "SETTLE_TIMEOUT_SECS" => "3", "SSM_POLL_SECS" => "0.1" }.merge(env)
  end

  def deploy_call(verb, target, *argv)
    Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks", argv: ["deploy", verb, target, *argv, "--wait"])
  end

  # Runs the verb against the runner's scripts with the stand-in programs on PATH.
  def command(verb, *argv, env: {})
    settings = stub_env(env)
    saved = ENV.to_h.slice(*settings.keys)
    ENV.update(settings)
    out, status = deploy_call(verb, File.join(runner.dir, "scripts"), *argv)
    [JSON.parse(out), status]
  ensure
    settings&.each_key { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  def settled(names: %w[website cms])
    up = (names + ["caddy"]).map { |name| "#{name} Up 3 minutes" }
    images = names.to_h { |name| [name, "#{registry}/widget-#{name}:#{name}-old"] }
    runner.box_report(compose: images, containers: up.join("\n"))
  end

  def settled_and_pinned
    settled(names: %w[website cms domain])
    runner.pin_task_definition("widget-platform:7", PLATFORM_TAGS)
  end

  # Rolls the cms service to a tag that is already in ECR; `env` adds to the stand-in environment.
  def roll_cms_existing(**env)
    command("service_roll.run", "service=cms", "existing_tag=cms-old", env: { "STUB_ECR_HAS_TAG" => "1" }.merge(env))
  end

  # The status of the SmokeRun that the roll's policy requested under the roll's own run key.
  def smoke_status(json)
    out, = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                        argv: ["deploy", "smoke_run.verdict", "run=#{json.fetch("run")}"])
    JSON.parse(out).first&.fetch("status")
  end

  def smoke_dispatched? = runner.calls.any? { |call| call.start_with?("gh workflow run") }

  # The named fields of a roll's state: its status as is, every other field as its value.
  def state_of(json, *fields)
    state = json.fetch("state")
    fields.to_h { |field| [field, field == "status" ? state[field] : state.dig(field, "value")] }
  end

  def refusal_of(json) = json.dig("state", "refusal", "value")

  it "declares both rolls in the Deploy chapter, with the DeployToolchain port they ask", :aggregate_failures do
    chapter = @hecks.registry.bluebook("Deploy")

    expect(chapter.aggregate("ServiceRoll").commands.map(&:hecks_name)).to eq(%w[Run Complete Flag Verify FlagSmoke])
    expect(chapter.aggregate("BoxRoll").commands.map(&:hecks_name)).to eq(%w[Run Complete Flag Verify FlagSmoke])
  end

  describe "service_roll.run" do
    with_stub_runner :taskdef_golden

    it "rolls the service, records it as rolled with its tag and task definition, then smokes", :aggregate_failures do
      settled_and_pinned
      json, status = roll_cms_existing

      expect([status, state_of(json, "status", "tag", "taskdef")]).to eq([0, VERIFIED_STATE])
      expect(runner.calls).to include("deploy-box widget-platform:7")
      expect([smoke_dispatched?, smoke_status(json)]).to eq([true, "passed"])
    end

    it "flags the roll, and exits 1, when the smoke it requested fails", :aggregate_failures do
      settled_and_pinned
      json, status = roll_cms_existing("STUB_CONCLUSION" => "failure")

      expect([status, state_of(json, "status", "tag")]).to eq([1, { "status" => "flagged", "tag" => "cms-old" }])
      expect(refusal_of(json)).to include("smoke ended 22")
    end

    it "leaves the smoke out when skip_smoke=true", :aggregate_failures do
      json, status = command("service_roll.run", "service=cms", "skip_smoke=true")

      expect(status).to eq(0)
      expect(state_of(json, "status", "smoke")).to eq("status" => "rolled", "smoke" => "smoke skipped: skip_smoke=true")
      expect(runner.calls.grep(/\Agh /)).to be_empty
      expect(smoke_status(json)).to be_nil
    end

    it "flags a tag already in ECR as exit 31, pushing nothing", :aggregate_failures do
      json, status = command("service_roll.run", "service=cms", env: { "STUB_ECR_HAS_TAG" => "1" })

      expect([status, json.dig("state", "status"), smoke_status(json), smoke_dispatched?]).to eq([1, "flagged", nil, false])
      expect(refusal_of(json)).to include("service roll ended 31 (the fresh tag is already in ECR)")
      expect(runner.calls.grep(/push/)).to be_empty
    end

    it "flags a stack update that failed as exit 35, without rolling or smoking", :aggregate_failures do
      runner.stack_status("UPDATE_ROLLBACK_COMPLETE")
      json, status = command("service_roll.run", "service=cms")

      expect(status).to eq(1)
      expect(refusal_of(json)).to include("ended 35 (the stack update failed")
      expect(runner.calls.grep(/deploy-box/)).to be_empty
    end

    it "flags an unknown service as exit 2, and refuses a name that is not a container name", :aggregate_failures do
      json, status = command("service_roll.run", "service=nope")
      expect([status, refusal_of(json)]).to match([1, a_string_including("ended 2 (unknown service)", "unknown service 'nope'")])

      out, status = deploy_call("service_roll.run", runner.dir, "service=Bad Name")
      expect(status).not_to eq(0)
      expect(out).to match(/service/i)
    end

    it "redeploys an existing tag without pushing", :aggregate_failures do
      runner.parameters(PARAMETERS)
      json, status = command("service_roll.run", "service=cms", "existing_tag=cms-keep", "skip_smoke=true", env: REDEPLOY_ENV)

      expect([status, state_of(json, "tag")]).to eq([0, { "tag" => "cms-keep" }])
      expect(runner.calls.grep(/push|docker tag/)).to be_empty
    end

    it "flags an existing tag that is not in ECR as exit 30" do
      runner.parameters(PARAMETERS)
      json, status = command("service_roll.run", "service=cms", "existing_tag=cms-gone")

      expect([status, refusal_of(json)]).to match([1, a_string_including("ended 30 (the existing tag is not in ECR)")])
    end
  end

  describe "box_roll.run" do
    with_stub_runner :services_golden, real_box: true

    it "rolls the box with the tags it is given, records it, then smokes", :aggregate_failures do
      settled
      json, status = command("box_roll.run", ROLL_TAGS)

      expect([status, json.dig("state", "status"), smoke_dispatched?]).to eq([0, "verified", true])
      expect(state_of(json, "report")["report"]).to include("box roll done")
      expect(runner.calls.grep(/ssm send-command/).size).to be >= 2
    end

    it "flags the roll, and exits 1, when the smoke it requested fails", :aggregate_failures do
      settled
      json, status = command("box_roll.run", ROLL_TAGS, env: { "STUB_CONCLUSION" => "failure" })

      expect([status, json.dig("state", "status"), smoke_status(json)]).to eq([1, "flagged", "flagged"])
      expect(refusal_of(json)).to include("smoke ended 22 (the smoke failed)")
      expect(state_of(json, "report")["report"]).to include("box roll done")
    end

    it "rolls a project with no smoke script and records that the smoke was skipped for that", :aggregate_failures do
      FileUtils.rm(File.join(runner.dir, "scripts", "smoke-after-deploy.sh"))
      json, status = command("box_roll.run", ROLL_TAGS)

      expect(state_of(json, "status", "smoke")).to eq("status" => "rolled", "smoke" => "smoke skipped: no smoke script")
      expect([status, smoke_status(json)]).to eq([0, nil])
      expect(runner.calls.grep(/\Agh /)).to be_empty
    end

    it "flags a box with no instance as exit 40", :aggregate_failures do
      File.write(File.join(runner.dir, "bin", "aws"), "#!/usr/bin/env bash\necho None\n")
      json, status = command("box_roll.run", "tags=website=t1")

      expect([status, json.dig("state", "status"), smoke_dispatched?]).to eq([1, "flagged", false])
      expect(refusal_of(json)).to include("box roll ended 40 (the box stack has no instance)")
    end

    it "flags a roll that fails on the box as exit 41", :aggregate_failures do
      aws = File.read(File.join(runner.dir, "bin", "aws")).sub("*) echo Success ;;", "*) echo Failed ;;")
      File.write(File.join(runner.dir, "bin", "aws"), aws)
      json, status = command("box_roll.run", "tags=website=t1")

      expect(status).to eq(1)
      expect(refusal_of(json)).to include("ended 41 (the roll did not succeed on the box)")
    end
  end

  describe "box_roll.run for a task-definition project" do
    with_stub_runner :taskdef_golden

    it "names the task definition, and can leave the smoke out", :aggregate_failures do
      json, status = command("box_roll.run", "taskdef=widget-platform:5", "skip_smoke=true")

      expect(status).to eq(0)
      expect(runner.calls).to include("deploy-box widget-platform:5")
      expect(state_of(json, "taskdef")).to eq("taskdef" => "widget-platform:5")
      expect(runner.calls.grep(/gh /)).to be_empty
    end
  end

  # The generated Makefile and hosting.mk call the commands. A stand-in `hecks` answers them, so the
  # recipes' own logic (arguments, the missing-database path) runs for real.
  describe "the generated Makefile" do
    with_stub_runner :taskdef_golden

    let(:fake_hecks) do
      <<~BASH
        #!/usr/bin/env bash
        echo "hecks $*" >> "$STUB_DIR/calls.log"
        case "$2" in
          smoke_run.verdict) passed='[{"status": "passed"}]'; echo "${FAKE_VERDICT:-$passed}" ;;
          *) [ -z "${FAKE_NO_DATABASE:-}" ] || { echo "cannot open Hecks: no database at localhost" >&2; exit 1; }
             exit "${FAKE_ROLL_STATUS:-0}" ;;
        esac
      BASH
    end

    def install_fake_hecks
      hecks = File.join(runner.dir, "bin", "hecks")
      File.write(hecks, fake_hecks)
      File.chmod(0o755, hecks)
    end

    def make(*args, env: {})
      scripts = File.join(runner.dir, "scripts")
      %w[Makefile hosting.mk].each { |f| FileUtils.cp(File.join(taskdef_golden, f), scripts) }
      install_fake_hecks
      _out, err, status = Open3.capture3(stub_env(env), "make", "-C", scripts, *args)
      [err, status.exitstatus]
    end

    # A project with the plain default Makefile, which has none of the hosting scripts.
    def plain_project
      plain = File.join(runner.dir, "plain")
      FileUtils.mkdir_p(plain)
      FileUtils.cp(File.join(__dir__, "fixtures", "deploy_box_golden", "default", "Makefile"), plain)
      install_fake_hecks
      plain
    end

    it "deploy runs box_roll.run with the task definition and reads nothing else", :aggregate_failures do
      err, status = make("deploy", "TASKDEF=widget-platform:5")

      expect(status).to eq(0), err
      deploy_line = %r{\Ahecks deploy box_roll.run project=.+/scripts run=deploy-\d+ taskdef=widget-platform:5}
      expect(runner.calls.first).to match(deploy_line)
      expect(runner.calls.grep(/\Ahecks /).size).to eq(1)
    end

    it "deploy fails when the command fails, whether the roll or its smoke was flagged" do
      _err, status = make("deploy", env: { "FAKE_ROLL_STATUS" => "1" })

      expect(status).not_to eq(0)
    end

    it "deploy of a project without the hosting scripts is box_roll.run too, with its tags", :aggregate_failures do
      _out, err, status = Open3.capture3(stub_env, "make", "-C", plain_project, "deploy", "TAGS=web=1")

      expect(status.exitstatus).to eq(0), err
      expect(runner.calls.first).to match(%r{\Ahecks deploy box_roll.run project=.+/plain run=deploy-\d+ tags=web=1})
    end

    it "deploy passes SKIP_POST_DEPLOY_SMOKE on as skip_smoke", :aggregate_failures do
      _err, status = make("deploy", env: { "SKIP_POST_DEPLOY_SMOKE" => "1" })

      expect(status).to eq(0)
      expect(runner.calls.grep(/box_roll.run.*skip_smoke=true/).size).to eq(1)
    end

    it "deploy still rolls without the database, says so, and exits 24 when everything passed", :aggregate_failures do
      settled(names: %w[website cms domain])
      err, status = make("deploy", env: { "FAKE_NO_DATABASE" => "1" })

      expect(status).not_to eq(0)
      expect(err).to include("the deploy record was NOT written", "non-superuser role", "Error 24")
      expect([runner.calls.grep(/\Adeploy-box/).size, smoke_dispatched?]).to eq([1, true])
    end

    it "deploy-service runs service_roll.run for the service, and passes an existing tag on", :aggregate_failures do
      err, status = make("deploy-service", "SERVICE=cms", "EXISTING_TAG=cms-keep")

      expect(status).to eq(0), err
      expect(runner.calls.first).to match(/service_roll.run project=.+ run=deploy-\d+ service=cms existing_tag=cms-keep/)
    end

    it "deploy-service runs the script itself without the database and exits non-zero", :aggregate_failures do
      settled_and_pinned
      err, status = make("deploy-service", "SERVICE=cms", env: ROLL_NO_DATABASE_ENV)

      expect(status).not_to eq(0)
      expect(err).to include("the deploy record was NOT written", "Error 24")
      expect(runner.calls.grep(/docker .*push/)).to be_empty
    end
  end

  describe "finding the script" do
    let(:dir) { Dir.mktmpdir }

    after { FileUtils.rm_rf(dir) }

    def two_scripts
      %w[a b].each do |sub|
        FileUtils.mkdir_p(File.join(dir, sub))
        File.write(File.join(dir, sub, "deploy-box.sh"), "echo #{sub}\n")
      end
    end

    it "names the missing script when there is none beside the Makefile", :aggregate_failures do
      out, status = deploy_call("box_roll.run", dir)

      expect(status).to eq(1)
      expect(JSON.parse(out).dig("state", "refusal", "value")).to include("no deploy-box.sh under")
    end

    it "names script= when two scripts are found", :aggregate_failures do
      two_scripts
      out, = deploy_call("box_roll.run", dir, "skip_smoke=true")

      expect(JSON.parse(out).dig("state", "refusal", "value")).to include("2 deploy-box.sh files", "script=<path>")
    end

    it "runs the script that script= names", :aggregate_failures do
      two_scripts
      out, status = deploy_call("box_roll.run", dir, "script=#{File.join(dir, "b", "deploy-box.sh")}", "skip_smoke=true")

      expect(status).to eq(0)
      expect(JSON.parse(out).dig("state", "report", "value")).to eq("b")
    end
  end
end
