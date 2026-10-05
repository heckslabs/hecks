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
  let(:taskdef_golden)  { File.join(__dir__, "fixtures", "deploy_box_golden", "hosting_taskdef") }
  let(:services_golden) { File.join(__dir__, "fixtures", "deploy_box_golden", "hosting_services") }
  let(:registry)        { BoxHostingStubs::REGISTRY }

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
  end

  # Runs the verb with the stand-in programs first on PATH, as the generated scripts find them.
  def command(runner, verb, *argv, env: {})
    settings = { "PATH" => "#{File.join(runner.dir, 'bin')}:#{ENV.fetch('PATH')}", "STUB_DIR" => runner.dir,
                 "SETTLE_CHECK_INTERVAL_SECS" => "1", "SETTLE_TIMEOUT_SECS" => "3", "SSM_POLL_SECS" => "0.1" }
    saved = ENV.to_h.slice(*settings.merge(env).keys)
    ENV.update(settings.merge(env))
    out, status = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                               argv: ["deploy", verb, File.join(runner.dir, "scripts"), *argv, "--wait"])
    [JSON.parse(out), status]
  ensure
    settings.merge(env).each_key { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  def settled(runner, names: %w[website cms])
    up = (names + ["caddy"]).map { |name| "#{name} Up 3 minutes" }
    images = names.to_h { |name| [name, "#{registry}/widget-#{name}:#{name}-old"] }
    runner.box_report(compose: images, containers: up.join("\n"))
  end

  # The status of the SmokeRun that the roll's policy requested under the roll's own run key.
  def smoke_status(json)
    out, = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                        argv: ["deploy", "smoke_run.verdict", "run=#{json.fetch('run')}"])
    JSON.parse(out).first&.fetch("status")
  end

  def smoke_dispatched?(runner) = runner.calls.any? { |call| call.start_with?("gh workflow run") }

  it "declares both rolls in the Deploy chapter, with the DeployToolchain port they ask" do
    chapter = @hecks.registry.bluebook("Deploy")

    expect(chapter.aggregate("ServiceRoll").commands.map(&:hecks_name)).to eq(%w[Run Complete Flag])
    expect(chapter.aggregate("BoxRoll").commands.map(&:hecks_name)).to eq(%w[Run Complete Flag])
  end

  describe "service_roll.run" do
    it "rolls the service, records it as rolled with its tag and task definition, then smokes" do
      BoxHostingStubs.with_runner(taskdef_golden) do |runner|
        settled(runner, names: %w[website cms domain])

        runner.pin_task_definition("widget-platform:7", "website" => "website-old", "cms" => "cms-old",
                                                        "domain" => "domain-old")

        json, status = command(runner, "service_roll.run", "service=cms", "existing_tag=cms-old",
                               env: { "STUB_ECR_HAS_TAG" => "1" })

        expect(status).to eq(0), json.to_json
        expect(json.dig("state", "status")).to eq("rolled")
        expect(json.dig("state", "tag", "value")).to eq("cms-old")
        expect(json.dig("state", "taskdef", "value")).to eq("widget-platform:7")
        expect(runner.calls).to include("deploy-box widget-platform:7")
        expect(smoke_dispatched?(runner)).to be(true)
        expect(smoke_status(json)).to eq("passed")
      end
    end

    it "leaves the smoke out when skip_smoke=true" do
      BoxHostingStubs.with_runner(taskdef_golden) do |runner|
        json, status = command(runner, "service_roll.run", "service=cms", "skip_smoke=true")

        expect(status).to eq(0)
        expect(json.dig("state", "status")).to eq("rolled")
        expect(runner.calls.grep(/\Agh /)).to be_empty
        expect(smoke_status(json)).to be_nil
      end
    end

    it "flags a tag already in ECR as exit 31, pushing nothing" do
      BoxHostingStubs.with_runner(taskdef_golden) do |runner|
        json, status = command(runner, "service_roll.run", "service=cms", env: { "STUB_ECR_HAS_TAG" => "1" })

        expect(status).to eq(1)
        expect(json.dig("state", "status")).to eq("flagged")
        expect(smoke_status(json)).to be_nil
        expect(json.dig("state", "refusal", "value")).to include("service roll ended 31 (the fresh tag is already in ECR)")
        expect(runner.calls.grep(/push/)).to be_empty
        expect(smoke_dispatched?(runner)).to be(false)
      end
    end

    it "flags a stack update that failed as exit 35, without rolling or smoking" do
      BoxHostingStubs.with_runner(taskdef_golden) do |runner|
        runner.stack_status("UPDATE_ROLLBACK_COMPLETE")

        json, status = command(runner, "service_roll.run", "service=cms")

        expect(status).to eq(1)
        expect(json.dig("state", "refusal", "value")).to include("ended 35 (the stack update failed")
        expect(runner.calls.grep(/deploy-box/)).to be_empty
      end
    end

    it "flags an unknown service as exit 2, and refuses a name that is not a container name" do
      BoxHostingStubs.with_runner(taskdef_golden) do |runner|
        json, status = command(runner, "service_roll.run", "service=nope")
        expect(status).to eq(1)
        expect(json.dig("state", "refusal", "value")).to include("ended 2 (unknown service)", "unknown service 'nope'")

        out, status = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                                   argv: ["deploy", "service_roll.run", runner.dir, "service=Bad Name", "--wait"])
        expect(status).not_to eq(0)
        expect(out).to match(/service/i)
      end
    end

    it "redeploys an existing tag without pushing, and flags one that is not in ECR as exit 30" do
      BoxHostingStubs.with_runner(taskdef_golden) do |runner|
        runner.parameters("WebsiteImageTag" => "website-old", "CmsImageTag" => "cms-keep",
                          "EngineImageTag" => "domain-old", "Other" => "x")

        json, status = command(runner, "service_roll.run", "service=cms", "existing_tag=cms-keep", "skip_smoke=true",
                               env: { "STUB_ECR_HAS_TAG" => "1", "STUB_NO_UPDATES" => "1" })
        expect(status).to eq(0)
        expect(json.dig("state", "tag", "value")).to eq("cms-keep")
        expect(runner.calls.grep(/push|docker tag/)).to be_empty

        json, status = command(runner, "service_roll.run", "service=cms", "existing_tag=cms-gone")
        expect(status).to eq(1)
        expect(json.dig("state", "refusal", "value")).to include("ended 30 (the existing tag is not in ECR)")
      end
    end
  end

  describe "box_roll.run" do
    it "rolls the box with the tags it is given, records it, then smokes" do
      BoxHostingStubs.with_runner(services_golden, real_box: true) do |runner|
        settled(runner)

        json, status = command(runner, "box_roll.run", "tags=website=website-old cms=cms-old")

        expect(status).to eq(0), json.to_json
        expect(json.dig("state", "status")).to eq("rolled")
        expect(json.dig("state", "report", "value")).to include("box roll done")
        expect(runner.calls.grep(/ssm send-command/).size).to be >= 2
        expect(smoke_dispatched?(runner)).to be(true)
      end
    end

    it "leaves the roll rolled when its smoke fails; the smoke's own record is flagged" do
      BoxHostingStubs.with_runner(services_golden, real_box: true) do |runner|
        settled(runner)

        json, status = command(runner, "box_roll.run", "tags=website=website-old cms=cms-old",
                               env: { "STUB_CONCLUSION" => "failure" })

        expect(status).to eq(0)
        expect(json.dig("state", "status")).to eq("rolled")
        expect(smoke_status(json)).to eq("flagged")
      end
    end

    it "names the task definition for a task-definition project, and can leave the smoke out" do
      BoxHostingStubs.with_runner(taskdef_golden) do |runner|
        json, status = command(runner, "box_roll.run", "taskdef=widget-platform:5", "skip_smoke=true")

        expect(status).to eq(0)
        expect(runner.calls).to include("deploy-box widget-platform:5")
        expect(json.dig("state", "taskdef", "value")).to eq("widget-platform:5")
        expect(runner.calls.grep(/gh /)).to be_empty
      end
    end

    it "flags a box with no instance as exit 40" do
      BoxHostingStubs.with_runner(services_golden, real_box: true) do |runner|
        File.write(File.join(runner.dir, "bin", "aws"), "#!/usr/bin/env bash\necho None\n")

        json, status = command(runner, "box_roll.run", "tags=website=t1")

        expect(status).to eq(1)
        expect(json.dig("state", "status")).to eq("flagged")
        expect(json.dig("state", "refusal", "value")).to include("box roll ended 40 (the box stack has no instance)")
        expect(smoke_dispatched?(runner)).to be(false)
      end
    end

    it "flags a roll that fails on the box as exit 41" do
      BoxHostingStubs.with_runner(services_golden, real_box: true) do |runner|
        aws = File.read(File.join(runner.dir, "bin", "aws")).sub("*) echo Success ;;", "*) echo Failed ;;")
        File.write(File.join(runner.dir, "bin", "aws"), aws)

        json, status = command(runner, "box_roll.run", "tags=website=t1")

        expect(status).to eq(1)
        expect(json.dig("state", "refusal", "value")).to include("ended 41 (the roll did not succeed on the box)")
      end
    end
  end

  # The generated Makefile and hosting.mk call the commands. A stand-in `hecks` answers them, so the
  # recipes' own logic (arguments, the smoke's verdict, the missing-database path) runs for real.
  describe "the generated Makefile" do
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

    def make(runner, *args, env: {})
      scripts = File.join(runner.dir, "scripts")
      %w[Makefile hosting.mk].each { |f| FileUtils.cp(File.join(taskdef_golden, f), scripts) }
      File.write(File.join(runner.dir, "bin", "hecks"), fake_hecks)
      File.chmod(0o755, File.join(runner.dir, "bin", "hecks"))
      settings = { "PATH" => "#{File.join(runner.dir, 'bin')}:#{ENV.fetch('PATH')}", "STUB_DIR" => runner.dir,
                   "SETTLE_CHECK_INTERVAL_SECS" => "1", "SETTLE_TIMEOUT_SECS" => "3", "SSM_POLL_SECS" => "0.1" }
      _out, err, status = Open3.capture3(settings.merge(env), "make", "-C", scripts, *args)
      [err, status.exitstatus]
    end

    it "deploy runs box_roll.run with the task definition, then reads the smoke's verdict" do
      BoxHostingStubs.with_runner(taskdef_golden) do |runner|
        err, status = make(runner, "deploy", "TASKDEF=widget-platform:5")

        expect(status).to eq(0), err
        expect(runner.calls.first)
          .to match(%r{\Ahecks deploy box_roll.run project=.+/scripts run=deploy-\d+ taskdef=widget-platform:5})
        expect(runner.calls.last).to match(/\Ahecks deploy smoke_run.verdict run=deploy-\d+\z/)
      end
    end

    it "deploy fails when the smoke did not pass, naming the verdict, and when the roll failed" do
      BoxHostingStubs.with_runner(taskdef_golden) do |runner|
        verdict = { "FAKE_VERDICT" => %([{"status": "flagged", "refusal": {"value": "smoke ended 22"}}]) }
        err, status = make(runner, "deploy", env: verdict)
        expect(status).not_to eq(0)
        expect(err).to include("the post-deploy smoke ended flagged", "smoke ended 22")

        _err, status = make(runner, "deploy", env: { "FAKE_ROLL_STATUS" => "1" })
        expect(status).not_to eq(0)
        expect(runner.calls.grep(/smoke_run.verdict/).size).to eq(1)
      end
    end

    it "deploy passes SKIP_POST_DEPLOY_SMOKE on as skip_smoke and reads no verdict" do
      BoxHostingStubs.with_runner(taskdef_golden) do |runner|
        _err, status = make(runner, "deploy", env: { "SKIP_POST_DEPLOY_SMOKE" => "1" })

        expect(status).to eq(0)
        expect(runner.calls.grep(/box_roll.run.*skip_smoke=true/).size).to eq(1)
        expect(runner.calls.grep(/verdict/)).to be_empty
      end
    end

    it "deploy still rolls without the database, says so, and exits 24 when everything passed" do
      BoxHostingStubs.with_runner(taskdef_golden) do |runner|
        settled(runner, names: %w[website cms domain])

        err, status = make(runner, "deploy", env: { "FAKE_NO_DATABASE" => "1" })

        expect(status).not_to eq(0)
        expect(err).to include("the deploy record was NOT written", "createdb hecks", "Error 24")
        expect(runner.calls.grep(/\Adeploy-box/).size).to eq(1)
        expect(smoke_dispatched?(runner)).to be(true)
      end
    end

    it "deploy-service runs service_roll.run for the service, and passes an existing tag on" do
      BoxHostingStubs.with_runner(taskdef_golden) do |runner|
        err, status = make(runner, "deploy-service", "SERVICE=cms", "EXISTING_TAG=cms-keep")

        expect(status).to eq(0), err
        expect(runner.calls.first).to match(/service_roll.run project=.+ run=deploy-\d+ service=cms existing_tag=cms-keep/)
      end
    end

    it "deploy-service runs the script itself without the database and exits non-zero" do
      BoxHostingStubs.with_runner(taskdef_golden) do |runner|
        settled(runner, names: %w[website cms domain])
        runner.pin_task_definition("widget-platform:7", "website" => "website-old", "cms" => "cms-old",
                                                        "domain" => "domain-old")

        err, status = make(runner, "deploy-service", "SERVICE=cms",
                           env: { "FAKE_NO_DATABASE" => "1", "EXISTING_TAG" => "cms-old", "STUB_ECR_HAS_TAG" => "1" })

        expect(status).not_to eq(0)
        expect(err).to include("the deploy record was NOT written", "Error 24")
        expect(runner.calls.grep(/docker .*push/)).to be_empty
      end
    end
  end

  it "finds the script beside the Makefile, and names script= when it is not there or is ambiguous" do
    Dir.mktmpdir do |dir|
      out, status = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                                 argv: ["deploy", "box_roll.run", dir, "--wait"])
      expect(status).to eq(1)
      expect(JSON.parse(out).dig("state", "refusal", "value")).to include("no deploy-box.sh under")

      %w[a b].each do |sub|
        FileUtils.mkdir_p(File.join(dir, sub))
        File.write(File.join(dir, sub, "deploy-box.sh"), "echo #{sub}\n")
      end
      out, = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                          argv: ["deploy", "box_roll.run", dir, "skip_smoke=true", "--wait"])
      expect(JSON.parse(out).dig("state", "refusal", "value")).to include("2 deploy-box.sh files", "script=<path>")

      override = "script=#{File.join(dir, 'b', 'deploy-box.sh')}"
      out, status = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                                 argv: ["deploy", "box_roll.run", dir, override, "skip_smoke=true", "--wait"])
      expect(status).to eq(0)
      expect(JSON.parse(out).dig("state", "report", "value")).to eq("b")
    end
  end
end
