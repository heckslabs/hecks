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

  # The scripts and stand-in programs in a scratch directory for each example, named by `runner`.
  around do |example|
    BoxHostingStubs.with_runner(golden) do |box|
      @runner = box
      example.run
    end
  end

  attr_reader :runner

  before { settle }

  def stub_settings(env)
    { "PATH" => "#{File.join(runner.dir, "bin")}:#{ENV.fetch("PATH")}", "STUB_DIR" => runner.dir,
      "SETTLE_CHECK_INTERVAL_SECS" => "1", "SETTLE_TIMEOUT_SECS" => "3", "SSM_POLL_SECS" => "0.1" }.merge(env)
  end

  # Runs the block with the stand-in programs first on PATH, as the generated script finds them.
  def with_stub_environment(env)
    settings = stub_settings(env)
    saved = ENV.to_h.slice(*settings.keys)
    ENV.update(settings)
    yield
  ensure
    settings.each_key { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  def run_smoke(*argv)
    Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks", argv: ["deploy", "smoke_run.run", *argv, "--wait"])
  end

  def smoke(*argv, env: {})
    with_stub_environment(env) do
      out, status = run_smoke(File.join(runner.dir, "scripts"), *argv)
      [JSON.parse(out), status]
    end
  end

  def settle
    up = (images.keys + ["caddy"]).map { |name| "#{name} Up 3 minutes" }
    runner.box_report(compose: images, containers: up.join("\n"))
  end

  def report_of(json) = json.dig("state", "report", "value")

  def refusal_of(json) = json.dig("state", "refusal", "value")

  it "is declared in the Deploy chapter, with the DeployToolchain port it asks" do
    commands = @hecks.registry.bluebook("Deploy").aggregate("SmokeRun").commands.map(&:hecks_name)

    expect(commands).to eq(%w[Run Pass Flag])
  end

  it "records a smoke that passed, with what the script printed", :aggregate_failures do
    json, status = smoke

    expect(status).to eq(0)
    expect(json.dig("state", "status")).to eq("passed")
    expect(report_of(json)).to include("post-deploy smoke passed")
    expect(runner.calls).to include("gh workflow run smoke-prod.yml --repo acme/widget-shop --ref main")
  end

  it "records a smoke that failed as flagged, names exit 22 and exits 1 under --wait", :aggregate_failures do
    json, status = smoke(env: { "STUB_CONCLUSION" => "failure" })

    expect(status).to eq(1)
    expect(json.dig("state", "status")).to eq("flagged")
    expect(refusal_of(json)).to include("smoke ended 22 (the smoke failed)", "smoke FAILED")
  end

  it "flags a roll that did not settle (exit 20) without dispatching anything", :aggregate_failures do
    runner.stack_status("UPDATE_ROLLBACK_COMPLETE")
    json, status = smoke

    expect(status).to eq(1)
    expect(refusal_of(json)).to include("smoke ended 20 (the roll did not settle)")
    expect(runner.calls.grep(/workflow run/)).to be_empty
  end

  it "passes the record's taskdef and dry_run on to the script", :aggregate_failures do
    runner.pin_task_definition("widget-platform:5", "website" => "website-old", "cms" => "cms-old", "domain" => "domain-old")
    json, = smoke("taskdef=widget-platform:5", "dry_run=true")

    expect(report_of(json)).to include("Nothing dispatched")
    expect(runner.calls.grep(/describe-task-definition.*widget-platform:5/)).not_to be_empty
  end

  it "passes the record's skip on to the script" do
    json, = smoke("skip=true")

    expect(report_of(json)).to include("SKIPPED")
  end

  def refusal_for(*argv)
    out, status = run_smoke(*argv)
    [JSON.parse(out).dig("state", "refusal", "value"), status]
  end

  def project_with_generated_script
    File.join(runner.dir, "deploy-aws").tap do |project|
      FileUtils.mkdir_p(File.join(project, "box-generated"))
      File.write(File.join(project, "box-generated", "smoke-after-deploy.sh"), "echo found-it\n")
    end
  end

  it "finds the script beside the Makefile, or the only one under the project", :aggregate_failures do
    out, status = run_smoke(project_with_generated_script)

    expect(status).to eq(0)
    expect(JSON.parse(out).dig("state", "report", "value")).to eq("found-it")
  end

  it "flags a project with no script, and names script= as the way out", :aggregate_failures do
    FileUtils.mkdir_p(File.join(runner.dir, "empty"))
    reason, status = refusal_for(File.join(runner.dir, "empty"))

    expect(status).to eq(1)
    expect(reason).to include("no smoke-after-deploy.sh under")
  end

  def project_with_two_scripts
    File.join(runner.dir, "two-scripts").tap do |dir|
      ["a", "b"].each do |sub|
        FileUtils.mkdir_p(File.join(dir, sub))
        File.write(File.join(dir, sub, "smoke-after-deploy.sh"), "echo #{sub}\n")
      end
    end
  end

  it "flags a project with several scripts, and names script= as the way out" do
    reason, = refusal_for(project_with_two_scripts)

    expect(reason).to include("2 smoke-after-deploy.sh files", "script=<path>")
  end

  it "runs the script that script= names" do
    dir = project_with_two_scripts
    out, = run_smoke(dir, "script=#{File.join(dir, "b", "smoke-after-deploy.sh")}")

    expect(JSON.parse(out).dig("state", "report", "value")).to eq("b")
  end

  it "flags a script override that does not exist", :aggregate_failures do
    reason, status = refusal_for("/nonexistent", "script=/nonexistent/smoke.sh")

    expect(status).to eq(1)
    expect(reason).to include("no such script")
  end

  it "refuses a task definition that is not a family name, before anything runs", :aggregate_failures do
    out, status = run_smoke("x", "taskdef=a b")

    expect(status).not_to eq(0)
    expect(out).to match(/taskdef/i)
  end
end
