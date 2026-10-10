require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "support/deploy_roll_context"

# What the box roll sends and what calls it: the log capture the roll sends over SSM before it
# replaces a container, the generated Makefile and hosting.mk that call the commands, and how the
# Makefile finds the deploy script. Run against the same stand-in programs as
# `hecks_deploy_roll_spec.rb`; nothing reaches AWS or GitHub.
RSpec.describe "the box roll's log capture and the generated Makefile", :io do
  include_context "with the deploy roll stand-ins"

  # The log capture the roll sends over SSM before it replaces a container. The sent script runs for
  # real against a stand-in `docker` that holds two running containers, in a scratch directory.
  describe "the log capture before a box roll" do
    with_stub_runner :services_golden, real_box: true

    LOG_SECRET = "SECRET-LINE-IN-A-LOG".freeze

    # The scripts the roll sent over SSM as base64, decoded, in the order they were sent.
    def sent_scripts
      runner.calls.join("\n").scan(/echo (\S+) \| base64 -d \| bash/).flatten.map { |b64| b64.unpack1("m") }
    end

    def install_docker(logs_ok: true)
      File.write(File.join(runner.dir, "bin", "docker"), <<~BASH)
        #!/usr/bin/env bash
        echo "docker $*" >> "$STUB_DIR/calls.log"
        case "$*" in
          *"ps --format"*) printf 'cms widget-cms-1\\nwebsite widget-website-1\\n' ;;
          "logs "*) #{logs_ok ? "echo #{LOG_SECRET}" : "exit 1"} ;;
        esac
      BASH
      FileUtils.chmod(0o755, File.join(runner.dir, "bin", "docker"))
    end

    def roll_once(**env)
      settled
      command("box_roll.run", ROLL_TAGS, "skip_smoke=true", env: env)
    end

    # The environment that points the captured script's paths at the scratch directory.
    def capture_env(env)
      box = File.join(runner.dir, "box")
      FileUtils.mkdir_p(box)
      File.write(File.join(box, "compose.json"), "{}")
      stub_env({ "CAPTURE_HOME" => box, "CAPTURE_DIR" => File.join(runner.dir, "captures"),
                 "CAPTURE_DF_PATH" => runner.dir, "CAPTURE_MIN_FREE_KB" => "0" }.merge(env))
    end

    # The script a roll sends. Every roll sends the same one, so the first example to ask rolls and
    # the others in the group reuse it instead of waiting out a roll each.
    def sent_capture_script
      self.class.instance_variable_get(:@sent_capture_script) ||
        self.class.instance_variable_set(:@sent_capture_script, begin
          roll_once
          sent_scripts.first
        end)
    end

    # Runs the script a roll sends as the box would.
    def capture(only: "", logs_ok: true, env: {})
      script = sent_capture_script
      install_docker(logs_ok: logs_ok)
      script = "ONLY='#{only}'\n#{script.sub(/\AONLY='[^']*'\n/, "")}"
      Open3.capture2e(capture_env(env), "bash", "-c", script)
    end

    def captured = Dir.glob(File.join(runner.dir, "captures", "*.log")).map { |f| File.basename(f) }.sort

    def seed_captures(count)
      dir = File.join(runner.dir, "captures")
      FileUtils.mkdir_p(dir)
      (1..count).each { |n| FileUtils.touch(File.join(dir, format("widget-cms-1-202601%02dT000000Z.log", n))) }
    end

    def mode_of(name) = File.stat(File.join(runner.dir, "captures", name)).mode & 0o777

    it "is sent before the step that replaces the containers", :aggregate_failures do
      roll_once
      sends = runner.calls.join("\n").split(/^aws ssm send-command/).drop(1)

      expect(sent_scripts.first).to include("docker logs", "/var/log/hecks-captures")
      expect(sends.index { |s| s.include?("up -d") }).to be > sends.index { |s| s.include?("base64 -d") }
    end

    it "is skipped with SKIP_LOG_CAPTURE=1" do
      roll_once("SKIP_LOG_CAPTURE" => "1")

      expect(sent_scripts.grep(/docker logs/)).to be_empty
    end

    it "saves each running container's log under a dated name, prints path and size, never the log", :aggregate_failures do
      out, status = capture

      expect(out).to match(%r{captured \S+/captures/widget-cms-1-\S+\.log \d+ bytes})
      expect(captured).to match([/\Awidget-cms-1-\d{8}T\d{6}Z\.log\z/, /\Awidget-website-1-\d{8}T\d{6}Z\.log\z/])
      expect([status.success?, out.include?(LOG_SECRET), mode_of(captured.first)]).to eq([true, false, 0o640])
    end

    it "captures only the services it is told to" do
      capture(only: "cms")

      expect(captured).to match([/\Awidget-cms-1-/])
    end

    it "keeps the newest 14 captures per container", :aggregate_failures do
      seed_captures(16)
      capture(only: "cms")

      expect(captured.grep(/widget-cms-1/).size).to eq(14)
      expect(captured).not_to include("widget-cms-1-20260101T000000Z.log", "widget-cms-1-20260102T000000Z.log")
    end

    it "skips with a warning when /var/log has under 2 GiB free", :aggregate_failures do
      out, status = capture(env: { "CAPTURE_MIN_FREE_KB" => "999999999999" })

      expect([status.success?, captured, out]).to match([true, [], a_string_including("WARNING log capture skipped")])
    end

    it "warns and goes on when a log cannot be read", :aggregate_failures do
      out, status = capture(logs_ok: false)

      expect([status.success?, captured, out]).to match([true, [], a_string_including("WARNING log capture failed")])
    end

    it "leaves the roll's status alone when the capture cannot be sent", :aggregate_failures do
      path = File.join(runner.dir, "bin", "aws")
      first_fails = '"ssm send-command") [ -e "$STUB_DIR/sent" ] || { touch "$STUB_DIR/sent"; exit 1; };'
      File.write(path, File.read(path).sub('"ssm send-command")', first_fails))
      json, status = roll_once

      expect([status, json.dig("state", "status")]).to eq([0, "rolled"])
    end
  end

  # The generated Makefile and hosting.mk call the commands. A stand-in `hecks` answers them, so the
  # recipes' own logic (arguments, the missing-database path) runs for real.
  # The point the database can be restored to, named before the roll changes anything, so a minted
  # era always has a way back that costs nothing to keep.
  describe "the restore anchor before a box roll" do
    with_stub_runner :services_golden, real_box: true

    def box_calls = runner.calls.grep(/\Aaws ssm send-command/)

    def backup_reads = runner.calls.grep(/\Aaws rds describe-db-instances/)

    it "names the instance and the moment it can be restored to, before anything reaches the box", :aggregate_failures do
      settled
      json, = command("box_roll.run", ROLL_TAGS, "skip_smoke=true")

      report = state_of(json, "report").fetch("report")
      expect(report).to include("restore anchor: db restorable to", "backups kept 7 days",
                                "restore-db-instance-to-point-in-time")
      expect(backup_reads.first).to include("--db-instance-identifier db")
      expect(runner.calls.index { |c| c.start_with?("aws rds") }).to be < runner.calls.index { |c| c.start_with?("aws ssm") }
    end

    it "refuses to roll when the backups are kept fewer days than MIN_BACKUP_RETENTION_DAYS", :aggregate_failures do
      settled
      json, = command("box_roll.run", ROLL_TAGS, "skip_smoke=true", env: { "STUB_BACKUP_DAYS" => "1" })

      expect(state_of(json, "status")).to eq("status" => "flagged")
      expect(refusal_of(json)).to match(/no restore anchor|43/)
      expect(box_calls).to be_empty
    end

    it "is skipped with SKIP_RESTORE_ANCHOR=1", :aggregate_failures do
      settled
      json, = command("box_roll.run", ROLL_TAGS, "skip_smoke=true",
                      env: { "STUB_BACKUP_DAYS" => "0", "SKIP_RESTORE_ANCHOR" => "1" })

      expect(state_of(json, "status")).to eq("status" => "rolled")
      expect(backup_reads).to be_empty
    end
  end

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
