require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"

# `hecks deploy companion_roll.run` end to end: the Deploy chapter's CompanionRoll asks the
# DeployToolchain port, the Hecks domain binds its adapter, and a stand-in `deploy-umami.sh` (the
# steps a project's companion script takes: read the task definition, send a Compose project over
# SSM, check it on the box) runs against a stand-in `aws`. Nothing reaches AWS or a box.
RSpec.describe "the Deploy chapter's CompanionRoll", :io do
  AWS_COMPANION_STUB = <<~BASH.freeze
    #!/usr/bin/env bash
    echo "aws $*" >> "$STUB_DIR/calls.log"
  BASH

  COMPANION_SCRIPT_STUB = <<~'BASH'.freeze
    #!/usr/bin/env bash
    set -euo pipefail
    echo "deploy-umami.sh $*" >> "$STUB_DIR/calls.log"
    out() { aws cloudformation describe-stacks --stack-name "$1" --query "Outputs[?OutputKey==\`$2\`]" --output text; }
    BOX=$(out widget-box InstanceId)
    UTD=${1:-umami:4}
    [ -z "${STUB_NO_BOX:-}" ] || { echo "no box instance (stack widget-box)" >&2; exit 1; }
    CMDS='["mkdir -p /opt/widget/umami","docker compose -p umami -f compose.json up -d"]'
    echo "==> deploying Umami ($UTD) to $BOX"
    aws ssm send-command --document-name AWS-RunShellScript --parameters "$CMDS"
    [ -z "${STUB_UNHEALTHY:-}" ] || { echo "==> Umami is NOT healthy on the box" >&2; exit 1; }
    echo "umami Up 15 seconds"
    echo "==> Umami is up on the box"
  BASH

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
  end

  def with_project(script: true)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p([File.join(dir, "bin"), File.join(dir, "project", "umami")])
      File.write(File.join(dir, "bin", "aws"), AWS_COMPANION_STUB)
      File.chmod(0o755, File.join(dir, "bin", "aws"))
      if script
        path = File.join(dir, "project", "umami", "deploy-umami.sh")
        File.write(path, COMPANION_SCRIPT_STUB)
        File.chmod(0o755, path)
      end
      yield dir
    end
  end

  def roll(dir, *argv, env: {})
    settings = { "PATH" => "#{File.join(dir, 'bin')}:#{ENV.fetch('PATH')}", "STUB_DIR" => dir }.merge(env)
    saved = ENV.to_h.slice(*settings.keys)
    ENV.update(settings)
    out, status = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                               argv: ["deploy", "companion_roll.run", File.join(dir, "project"),
                                                      *argv, "--wait"])
    [JSON.parse(out), status]
  ensure
    settings.each_key { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  def calls(dir)
    path = File.join(dir, "calls.log")
    File.exist?(path) ? File.readlines(path, chomp: true) : []
  end

  it "declares the roll and its recorders in the Deploy chapter" do
    commands = @hecks.registry.bluebook("Deploy").aggregate("CompanionRoll").commands.map(&:hecks_name)

    expect(commands).to eq(%w[Run Complete Plan Flag])
  end

  it "refuses without confirm=true, names the plan read from the script, and runs nothing" do
    with_project do |dir|
      json, status = roll(dir, "taskdef=umami:4")

      expect(status).to eq(1)
      expect(json.dig("state", "status")).to eq("flagged")
      expect(json.dig("state", "refusal", "value")).to include(
        "refusing to roll umami", "Compose project umami in /opt/widget/umami", "task definition umami:4",
        "stack widget-box", "over SSM", "confirm=true"
      )
      expect(calls(dir)).to be_empty
    end
  end

  it "prints the plan for dry_run=true, runs nothing, even with confirm=true" do
    with_project do |dir|
      json, status = roll(dir, "taskdef=umami:4", "confirm=true", "dry_run=true")

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("planned")
      expect(json.dig("state", "report", "value")).to include("dry run: nothing was run")
      expect(calls(dir)).to be_empty
    end
  end

  it "rolls when confirmed, passing the task definition, and records the box check" do
    with_project do |dir|
      json, status = roll(dir, "taskdef=umami:4", "confirm=true")

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("rolled")
      expect(json.dig("state", "report", "value")).to include("umami Up 15 seconds", "Umami is up on the box")
      expect(calls(dir)).to include("deploy-umami.sh umami:4")
    end
  end

  it "flags a companion that is not healthy on the box (exit 1, the script's status in the reason)" do
    with_project do |dir|
      json, status = roll(dir, "taskdef=umami:4", "confirm=true", env: { "STUB_UNHEALTHY" => "1" })

      expect(status).to eq(1)
      expect(json.dig("state", "status")).to eq("flagged")
      expect(json.dig("state", "refusal", "value")).to include("companion roll ended 1", "Umami is NOT healthy")
    end
  end

  it "flags a stack with no box instance" do
    with_project do |dir|
      json, status = roll(dir, "taskdef=umami:4", "confirm=true", env: { "STUB_NO_BOX" => "1" })

      expect(status).to eq(1)
      expect(json.dig("state", "refusal", "value")).to include("no box instance")
    end
  end

  it "finds the script of another companion by name, and says how to name one when there is none" do
    with_project(script: false) do |dir|
      json, status = roll(dir, "taskdef=umami:4", "companion=metrics", "confirm=true")

      expect(status).to eq(1)
      expect(json.dig("state", "refusal", "value")).to include("no deploy-metrics.sh", "script=<path>")
    end
  end

  it "lists the rolls that were flagged" do
    with_project do |dir|
      roll(dir, "taskdef=umami:4")
      out, = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks", argv: %w[deploy companion_roll.flagged])

      expect(JSON.parse(out).map { |row| row["status"] }).to include("flagged")
    end
  end
end
