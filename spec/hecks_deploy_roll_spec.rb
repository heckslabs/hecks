require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "support/deploy_roll_context"

# `hecks deploy service_roll.run` and `box_roll.run` end to end: the Deploy chapter's ServiceRoll
# and BoxRoll ask the DeployToolchain port, the Hecks domain binds its adapter, and the generated
# `deploy-service.sh` and `deploy-box.sh` (the golden files) run against stand-in `aws`, `docker`
# and `gh` programs. A successful roll's policy requests a SmokeRun. Nothing reaches AWS or GitHub.
# The log capture and the generated Makefile are in `hecks_deploy_roll_scripts_spec.rb`.
RSpec.describe "the Deploy chapter's ServiceRoll and BoxRoll", :io do
  include_context "with the deploy roll stand-ins"

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
      expect(runner.calls).to include("deploy-box widget-platform:7", "capture-scope=cms skip=")
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
end
