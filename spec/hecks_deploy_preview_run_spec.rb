require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"

# `hecks deploy preview_run.<verb>` end to end: the Deploy chapter's PreviewRun asks the
# DeployToolchain port, the Hecks domain binds its adapter, and a stand-in `preview.sh` (a script
# with the verbs and refusals a project's preview script has) runs against a stand-in `aws`. Nothing
# reaches AWS, a registry or a database.
RSpec.describe "the Deploy chapter's PreviewRun", :io do
  AWS_PREVIEW_STUB = <<~BASH.freeze
    #!/usr/bin/env bash
    echo "aws $*" >> "$STUB_DIR/calls.log"
    case "$1 $2" in
      "cloudformation describe-stacks") echo "https://preview.example.test" ;;
    esac
  BASH

  # The verbs and refusals of a project's preview script: names from the branch, main and master
  # refused, every failure a status 1, a bad verb 2.
  PREVIEW_SCRIPT_STUB = <<~BASH.freeze
    #!/usr/bin/env bash
    set -euo pipefail
    REGION=us-east-1
    PREFIX=widget-preview
    echo "preview.sh $* branch=${BRANCH:-}" >> "$STUB_DIR/calls.log"
    die() { echo "error: $*" >&2; exit 1; }
    BRANCH="${BRANCH:-feature/x}"
    case "$BRANCH" in main|master) die "refusing to make a preview of $BRANCH" ;; esac
    env=$(printf '%s' "$BRANCH" | tr '[:upper:]/' '[:lower:]-')
    case "${1:-}" in
      name) echo "stack:    $PREFIX-$env" ;;
      url) [ -z "${STUB_NO_STACK:-}" ] || die "no preview for branch '$BRANCH'"; aws cloudformation describe-stacks ;;
      list) aws cloudformation describe-stacks --region "$REGION" ;;
      deploy) aws cloudformation deploy --stack-name "$PREFIX-$env"; echo "Preview is up" ;;
      destroy) aws cloudformation delete-stack --stack-name "$PREFIX-$env"; echo "Deleted." ;;
      login) aws secretsmanager get-secret-value; echo "Signing in to the preview (good for 8 hours)" ;;
      *) echo "error: usage: preview.sh <deploy|destroy|list|url|name|login>" >&2; exit 1 ;;
    esac
  BASH

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
  end

  PREVIEW_STACK = "widget-preview-feature-a".freeze

  # Runs each example of the group inside a scratch project with the stand-in script beside a platform
  # directory and a stand-in `aws`; `script: false` leaves the script out.
  def self.with_project(script: true)
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        stage_project(dir, script)
        example.run
      end
    end
  end

  attr_reader :dir

  def install_stub(path, text)
    File.write(path, text)
    File.chmod(0o755, path)
  end

  def stage_project(dir, script)
    FileUtils.mkdir_p([File.join(dir, "bin"), File.join(dir, "project", "platform")])
    install_stub(File.join(dir, "bin", "aws"), AWS_PREVIEW_STUB)
    install_stub(File.join(dir, "project", "platform", "preview.sh"), PREVIEW_SCRIPT_STUB) if script
  end

  def deploy_call(verb, *argv)
    Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                 argv: ["deploy", verb, File.join(dir, "project"), *argv, "--wait"])
  end

  # Yields with `settings` in the environment, and puts every key back as it was afterwards.
  def with_env(settings)
    saved = ENV.to_h.slice(*settings.keys)
    ENV.update(settings)
    yield
  ensure
    settings.each_key { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  def preview(verb, *argv, env: {})
    settings = { "PATH" => "#{File.join(dir, "bin")}:#{ENV.fetch("PATH")}", "STUB_DIR" => dir }.merge(env)
    out, status = with_env(settings) { deploy_call("preview_run.#{verb}", *argv) }
    [JSON.parse(out), status]
  end

  def calls
    path = File.join(dir, "calls.log")
    File.exist?(path) ? File.readlines(path, chomp: true) : []
  end

  def state_status(json) = json.dig("state", "status")

  def report_of(json) = json.dig("state", "report", "value")

  def refusal_of(json) = json.dig("state", "refusal", "value")

  # What the refusal names when a write is not confirmed.
  def plan_phrases(verb)
    ["refusing to #{verb} a preview", "widget-preview-<name derived from feature-a>", "us-east-1", "confirm=true", "dry_run=true"]
  end

  it "declares the six verbs and their recorders in the Deploy chapter" do
    commands = @hecks.registry.bluebook("Deploy").aggregate("PreviewRun").commands.map(&:hecks_name)

    expect(commands).to eq(%w[Name Url List Deploy Destroy Login RecordName RecordUrl RecordList RecordDeploy
                              RecordDestroy RecordLogin Plan Flag])
  end

  describe "the reads, which need no confirmation" do
    with_project

    it "names a branch's preview, with no AWS call", :aggregate_failures do
      json, status = preview("name", "branch=Feature/Login")

      expect([status, state_status(json)]).to eq([0, "named"])
      expect(report_of(json)).to include("stack:    widget-preview-feature-login")
      expect(calls).to eq(["preview.sh name branch=Feature/Login"])
    end

    it "records the URL the script prints", :aggregate_failures do
      json, status = preview("url")

      expect([status, state_status(json)]).to eq([0, "located"])
      expect(report_of(json)).to eq("https://preview.example.test")
    end

    it "lists the previews", :aggregate_failures do
      json, = preview("list")

      expect(state_status(json)).to eq("listed")
      expect(calls).to include("aws cloudformation describe-stacks --region us-east-1")
    end

    it "flags a preview that does not exist (exit 1: the script's own refusal)", :aggregate_failures do
      json, status = preview("url", env: { "STUB_NO_STACK" => "1" })

      expect([status, state_status(json)]).to eq([1, "flagged"])
      expect(refusal_of(json)).to include("preview url ended 1 (the preview script refused or failed)", "no preview for branch")
    end
  end

  %w[deploy destroy login].each do |verb|
    describe "preview_run.#{verb}, which writes or reads secrets" do
      with_project

      it "refuses without confirm=true, names the plan, and runs nothing", :aggregate_failures do
        json, status = preview(verb, "branch=feature-a")

        expect([status, state_status(json)]).to eq([1, "flagged"])
        expect(refusal_of(json)).to include(*plan_phrases(verb))
        expect(calls).to be_empty
      end

      it "prints the plan for dry_run=true, runs nothing, even with confirm=true", :aggregate_failures do
        json, status = preview(verb, "confirm=true", "dry_run=true")

        expect([status, state_status(json)]).to eq([0, "planned"])
        expect(report_of(json)).to include("#{verb}:", "the checked-out branch", "dry run: nothing was run")
        expect(calls).to be_empty
      end
    end
  end

  describe "when confirmed" do
    with_project

    it "deploys, destroys and signs in, recording each outcome", :aggregate_failures do
      statuses = %w[deploy destroy login].map { |verb| state_status(preview(verb, "branch=feature-a", "confirm=true").first) }

      expect(statuses).to eq(%w[deployed destroyed signed_in])
      expect(calls).to include("aws cloudformation deploy --stack-name #{PREVIEW_STACK}",
                               "aws cloudformation delete-stack --stack-name #{PREVIEW_STACK}")
    end

    it "flags a script that fails, with its status, and exits 1", :aggregate_failures do
      json, status = preview("deploy", "confirm=true", env: { "BRANCH" => "main" })

      expect(status).to eq(1)
      expect(refusal_of(json)).to include("preview deploy ended 1", "refusing to make a preview of main")
    end
  end

  describe "a preview of main or master" do
    with_project

    it "is refused before anything runs: the branch is a given", :aggregate_failures do
      %w[main master].each do |branch|
        out, status = deploy_call("preview_run.deploy", "branch=#{branch}", "confirm=true")

        expect([status, calls]).to eq([1, []])
        expect(out).to include("a preview is never of main or master")
      end
    end
  end

  describe "a project with no preview script" do
    with_project script: false

    it "says how to name the script", :aggregate_failures do
      json, status = preview("name")

      expect(status).to eq(1)
      expect(refusal_of(json)).to include("no preview.sh", "script=<path>")
    end
  end

  describe "the record of runs" do
    with_project

    it "keeps every run, so a flagged one can be listed" do
      preview("url", env: { "STUB_NO_STACK" => "1" })
      out, = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks", argv: %w[deploy preview_run.flagged])

      expect(JSON.parse(out).map { |row| row["status"] }).to include("flagged")
    end
  end
end
