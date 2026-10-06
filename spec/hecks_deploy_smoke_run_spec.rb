require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require_relative "support/box_hosting_stubs"

# `hecks deploy smoke_run.run` end to end: the Deploy chapter's SmokeRun asks the DeployToolchain
# port, the Hecks domain binds its adapter, and the generated `smoke-after-deploy.sh` (the golden
# file) runs against stand-in `aws`, `docker` and `gh` programs. Nothing reaches AWS or GitHub.
RSpec.describe "the Deploy chapter's SmokeRun", :io do
  let(:golden)   { File.join(__dir__, "fixtures", "deploy_box_golden", "hosting_taskdef") }
  let(:registry) { BoxHostingStubs::REGISTRY }
  let(:images) do
    { "website" => "#{registry}/widget-website:website-old", "cms" => "#{registry}/widget-cms:cms-old",
      "domain" => "#{registry}/widget-domain:domain-old" }
  end

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
  end

  # Runs the verb with the stand-in programs first on PATH, as the generated script finds them.
  def smoke(runner, *argv, env: {})
    settings = { "PATH" => "#{File.join(runner.dir, "bin")}:#{ENV.fetch("PATH")}", "STUB_DIR" => runner.dir,
                 "SETTLE_CHECK_INTERVAL_SECS" => "1", "SETTLE_TIMEOUT_SECS" => "3", "SSM_POLL_SECS" => "0.1" }
    saved = ENV.to_h.slice(*settings.merge(env).keys)
    ENV.update(settings.merge(env))
    project = File.join(runner.dir, "scripts")
    out, status = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                               argv: ["deploy", "smoke_run.run", project, *argv, "--wait"])
    [JSON.parse(out), status]
  ensure
    settings.merge(env).each_key { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  def settled(runner)
    up = (images.keys + ["caddy"]).map { |name| "#{name} Up 3 minutes" }
    runner.box_report(compose: images, containers: up.join("\n"))
  end

  it "is declared in the Deploy chapter, with the DeployToolchain port it asks" do
    commands = @hecks.registry.bluebook("Deploy").aggregate("SmokeRun").commands.map(&:hecks_name)

    expect(commands).to eq(%w[Run Pass Flag])
  end

  it "records a smoke that passed, with what the script printed" do
    BoxHostingStubs.with_runner(golden) do |runner|
      settled(runner)

      json, status = smoke(runner)

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("passed")
      expect(json.dig("state", "report", "value")).to include("post-deploy smoke passed")
      expect(runner.calls).to include("gh workflow run smoke-prod.yml --repo acme/widget-shop --ref main")
    end
  end

  it "records a smoke that failed as flagged, names exit 22 and exits 1 under --wait" do
    BoxHostingStubs.with_runner(golden) do |runner|
      settled(runner)

      json, status = smoke(runner, env: { "STUB_CONCLUSION" => "failure" })

      expect(status).to eq(1)
      expect(json.dig("state", "status")).to eq("flagged")
      expect(json.dig("state", "refusal", "value")).to include("smoke ended 22 (the smoke failed)", "smoke FAILED")
    end
  end

  it "flags a roll that did not settle (exit 20) without dispatching anything" do
    BoxHostingStubs.with_runner(golden) do |runner|
      settled(runner)
      runner.stack_status("UPDATE_ROLLBACK_COMPLETE")

      json, status = smoke(runner)

      expect(status).to eq(1)
      expect(json.dig("state", "refusal", "value")).to include("smoke ended 20 (the roll did not settle)")
      expect(runner.calls.grep(/workflow run/)).to be_empty
    end
  end

  it "passes the record's taskdef, skip and dry_run on to the script" do
    BoxHostingStubs.with_runner(golden) do |runner|
      settled(runner)
      runner.pin_task_definition("widget-platform:5", "website" => "website-old", "cms" => "cms-old",
                                                      "domain" => "domain-old")

      json, = smoke(runner, "taskdef=widget-platform:5", "dry_run=true")
      expect(json.dig("state", "report", "value")).to include("Nothing dispatched")
      expect(runner.calls.grep(/describe-task-definition.*widget-platform:5/)).not_to be_empty

      json, = smoke(runner, "skip=true")
      expect(json.dig("state", "report", "value")).to include("SKIPPED")
    end
  end

  def refusal_for(*argv)
    out, status = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                               argv: ["deploy", "smoke_run.run", *argv, "--wait"])
    [JSON.parse(out).dig("state", "refusal", "value"), status]
  end

  it "finds the script beside the Makefile, or the only one under the project" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "deploy-aws", "box-generated"))
      script = File.join(dir, "deploy-aws", "box-generated", "smoke-after-deploy.sh")
      File.write(script, "echo found-it\n")

      out, status = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                                 argv: ["deploy", "smoke_run.run", dir, "--wait"])

      expect(status).to eq(0)
      expect(JSON.parse(out).dig("state", "report", "value")).to eq("found-it")
    end
  end

  it "flags a project with no script, or with several, and names script= as the way out" do
    Dir.mktmpdir do |dir|
      reason, status = refusal_for(dir)
      expect(status).to eq(1)
      expect(reason).to include("no smoke-after-deploy.sh under")

      %w[a b].each do |sub|
        FileUtils.mkdir_p(File.join(dir, sub))
        File.write(File.join(dir, sub, "smoke-after-deploy.sh"), "echo #{sub}\n")
      end
      reason, = refusal_for(dir)
      expect(reason).to include("2 smoke-after-deploy.sh files", "script=<path>")

      override = "script=#{File.join(dir, "b", "smoke-after-deploy.sh")}"
      out, = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                          argv: ["deploy", "smoke_run.run", dir, override, "--wait"])
      expect(JSON.parse(out).dig("state", "report", "value")).to eq("b")
    end
  end

  it "flags a script override that does not exist" do
    reason, status = refusal_for("/nonexistent", "script=/nonexistent/smoke.sh")

    expect(status).to eq(1)
    expect(reason).to include("no such script")
  end

  it "refuses a task definition that is not a family name, before anything runs" do
    out, status = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                               argv: ["deploy", "smoke_run.run", "x", "taskdef=a b", "--wait"])

    expect(status).not_to eq(0)
    expect(out).to match(/taskdef/i)
  end
end
