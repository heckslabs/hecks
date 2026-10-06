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

  # A scratch project with the stand-in script beside a platform directory and a stand-in `aws`.
  def with_project(script: true)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p([File.join(dir, "bin"), File.join(dir, "project", "platform")])
      File.write(File.join(dir, "bin", "aws"), AWS_PREVIEW_STUB)
      File.chmod(0o755, File.join(dir, "bin", "aws"))
      if script
        path = File.join(dir, "project", "platform", "preview.sh")
        File.write(path, PREVIEW_SCRIPT_STUB)
        File.chmod(0o755, path)
      end
      yield dir
    end
  end

  def preview(dir, verb, *argv, env: {})
    settings = { "PATH" => "#{File.join(dir, "bin")}:#{ENV.fetch("PATH")}", "STUB_DIR" => dir }.merge(env)
    saved = ENV.to_h.slice(*settings.keys)
    ENV.update(settings)
    out, status = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                               argv: ["deploy", "preview_run.#{verb}", File.join(dir, "project"),
                                                      *argv, "--wait"])
    [JSON.parse(out), status]
  ensure
    settings.each_key { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  def calls(dir)
    path = File.join(dir, "calls.log")
    File.exist?(path) ? File.readlines(path, chomp: true) : []
  end

  it "declares the six verbs and their recorders in the Deploy chapter" do
    commands = @hecks.registry.bluebook("Deploy").aggregate("PreviewRun").commands.map(&:hecks_name)

    expect(commands).to eq(%w[Name Url List Deploy Destroy Login RecordName RecordUrl RecordList RecordDeploy
                              RecordDestroy RecordLogin Plan Flag])
  end

  describe "the reads, which need no confirmation" do
    it "names a branch's preview, with no AWS call" do
      with_project do |dir|
        json, status = preview(dir, "name", "branch=Feature/Login")

        expect(status).to eq(0)
        expect(json.dig("state", "status")).to eq("named")
        expect(json.dig("state", "report", "value")).to include("stack:    widget-preview-feature-login")
        expect(calls(dir).grep(/\Aaws /)).to be_empty
        expect(calls(dir)).to eq(["preview.sh name branch=Feature/Login"])
      end
    end

    it "records the URL the script prints" do
      with_project do |dir|
        json, status = preview(dir, "url")

        expect(status).to eq(0)
        expect(json.dig("state", "status")).to eq("located")
        expect(json.dig("state", "report", "value")).to eq("https://preview.example.test")
      end
    end

    it "lists the previews" do
      with_project do |dir|
        json, = preview(dir, "list")

        expect(json.dig("state", "status")).to eq("listed")
        expect(calls(dir)).to include("aws cloudformation describe-stacks --region us-east-1")
      end
    end

    it "flags a preview that does not exist (exit 1: the script's own refusal)" do
      with_project do |dir|
        json, status = preview(dir, "url", env: { "STUB_NO_STACK" => "1" })

        expect(status).to eq(1)
        expect(json.dig("state", "status")).to eq("flagged")
        expect(json.dig("state", "refusal", "value")).to include(
          "preview url ended 1 (the preview script refused or failed)", "no preview for branch"
        )
      end
    end
  end

  %w[deploy destroy login].each do |verb|
    describe "preview_run.#{verb}, which writes or reads secrets" do
      it "refuses without confirm=true, names the plan, and runs nothing" do
        with_project do |dir|
          json, status = preview(dir, verb, "branch=feature-a")

          expect(status).to eq(1)
          expect(json.dig("state", "status")).to eq("flagged")
          expect(json.dig("state", "refusal", "value")).to include(
            "refusing to #{verb} a preview", "widget-preview-<name derived from feature-a>",
            "us-east-1", "confirm=true", "dry_run=true"
          )
          expect(calls(dir)).to be_empty
        end
      end

      it "prints the plan for dry_run=true, runs nothing, even with confirm=true" do
        with_project do |dir|
          json, status = preview(dir, verb, "confirm=true", "dry_run=true")

          expect(status).to eq(0)
          expect(json.dig("state", "status")).to eq("planned")
          expect(json.dig("state", "report",
                          "value")).to include("#{verb}:", "the checked-out branch", "dry run: nothing was run")
          expect(calls(dir)).to be_empty
        end
      end
    end
  end

  describe "when confirmed" do
    it "deploys, destroys and signs in, recording each outcome" do
      with_project do |dir|
        deployed, = preview(dir, "deploy", "branch=feature-a", "confirm=true")
        destroyed, = preview(dir, "destroy", "branch=feature-a", "confirm=true")
        login, = preview(dir, "login", "branch=feature-a", "confirm=true")

        expect(deployed.dig("state", "status")).to eq("deployed")
        expect(destroyed.dig("state", "status")).to eq("destroyed")
        expect(login.dig("state", "status")).to eq("signed_in")
        expect(calls(dir)).to include("aws cloudformation deploy --stack-name widget-preview-feature-a",
                                      "aws cloudformation delete-stack --stack-name widget-preview-feature-a")
      end
    end

    it "flags a script that fails, with its status, and exits 1" do
      with_project do |dir|
        json, status = preview(dir, "deploy", "confirm=true", env: { "BRANCH" => "main" })

        expect(status).to eq(1)
        expect(json.dig("state", "refusal", "value")).to include("preview deploy ended 1", "refusing to make a preview of main")
      end
    end
  end

  it "refuses main and master before anything runs: the branch is a given" do
    with_project do |dir|
      %w[main master].each do |branch|
        out, status = Hecks::Doors::CliRunner.call(
          runtime: @hecks, program: "hecks",
          argv: ["deploy", "preview_run.deploy", File.join(dir, "project"), "branch=#{branch}", "confirm=true", "--wait"]
        )

        expect(status).to eq(1)
        expect(out).to include("a preview is never of main or master")
        expect(calls(dir)).to be_empty
      end
    end
  end

  it "says how to name the script when the project has none" do
    with_project(script: false) do |dir|
      json, status = preview(dir, "name")

      expect(status).to eq(1)
      expect(json.dig("state", "refusal", "value")).to include("no preview.sh", "script=<path>")
    end
  end

  it "records every run, so a flagged one can be listed" do
    with_project do |dir|
      preview(dir, "url", env: { "STUB_NO_STACK" => "1" })
      out, = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks", argv: %w[deploy preview_run.flagged])

      expect(JSON.parse(out).map { |row| row["status"] }).to include("flagged")
    end
  end
end
