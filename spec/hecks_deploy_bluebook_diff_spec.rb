require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"

# `hecks deploy bluebook_diff.run` end to end: the Deploy chapter's BluebookDiff asks the
# DeployToolchain port, the Hecks domain binds its adapter, and the comparison runs in Ruby on two
# files, or by a stand-in `bluebooks-diff.sh` that prints what the project's script prints. Nothing
# reaches a registry, a docker daemon or AWS.
RSpec.describe "the Deploy chapter's BluebookDiff", :io do
  # Prints the report a project's script prints for the scenario in STUB_DIFF, and always ends 0.
  DIFF_SCRIPT_STUB = <<~BASH.freeze
    #!/usr/bin/env bash
    echo "bluebooks-diff $*" >> "$STUB_DIR/calls.log"
    case "${STUB_DIFF:-same}" in
      same) printf '==> bluebooks in this deploy (running image abc -> this build)\\n    cms  1.0.0   unchanged\\n    no bluebook changes.\\n' ;;
      moved) printf '==> bluebooks in this deploy (running image abc -> this build)\\n    cms  1.0.0 -> 1.1.0\\n' ;;
      nolabel) echo "==> bluebooks: the local domain image has no ai.example.bluebooks label; nothing to compare." ;;
      lookup) echo "==> bluebooks: could not read the running domain image's bluebooks (denied); nothing to compare." ;;
      first) echo "==> bluebooks: the running domain image (abc) predates the label; this deploy will be the first to report." ;;
      usage) echo "usage: bluebooks-diff.sh" >&2; exit 2 ;;
    esac
    exit 0
  BASH

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
  end

  def book(version:, shape: ["Cms 1"], digest: "aaaaaaaaaa", commit: "1234567890")
    { "bluebooks"  => { "cms" => { "version" => version, "shape" => shape, "digest" => digest } },
      "built_from" => { "commit" => commit, "dirty" => false } }
  end

  # A scratch project holding the stand-in script (unless `script` is false) and its files.
  def with_project(script: true)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "platform"))
      if script
        path = File.join(dir, "platform", "bluebooks-diff.sh")
        File.write(path, DIFF_SCRIPT_STUB)
        File.chmod(0o755, path)
      end
      yield dir
    end
  end

  def write_json(dir, name, data)
    File.join(dir, name).tap { |path| File.write(path, JSON.generate(data)) }
  end

  def diff(dir, *argv, env: {})
    settings = { "STUB_DIR" => dir }.merge(env)
    saved = ENV.to_h.slice(*settings.keys)
    ENV.update(settings)
    out, status = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                               argv: ["deploy", "bluebook_diff.run", dir, *argv, "--wait"])
    [JSON.parse(out), status]
  ensure
    settings.each_key { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  def calls(dir)
    path = File.join(dir, "calls.log")
    File.exist?(path) ? File.readlines(path, chomp: true) : []
  end

  it "is declared in the Deploy chapter, with the port it asks" do
    commands = @hecks.registry.bluebook("Deploy").aggregate("BluebookDiff").commands.map(&:hecks_name)

    expect(commands).to eq(%w[Run Match Differ Withhold Flag])
  end

  describe "with old= and new=" do
    it "records unchanged for two identical outputs, runs no script and exits 0" do
      with_project do |dir|
        same = write_json(dir, "a.json", book(version: "1.0.0"))

        json, status = diff(dir, "old=#{same}", "new=#{same}")

        expect(status).to eq(0)
        expect(json.dig("state", "status")).to eq("unchanged")
        expect(json.dig("state", "report", "value")).to include("cms", "unchanged", "no bluebook changes.")
        expect(calls(dir)).to be_empty
      end
    end

    it "records changed, exits 0, and marks a new era when the version and the shape both moved" do
      with_project do |dir|
        old = write_json(dir, "old.json", book(version: "1.0.0"))
        new = write_json(dir, "new.json", book(version: "2.0.0", shape: ["Cms 2"], commit: "abcdefabcdef"))

        json, status = diff(dir, "old=#{old}", "new=#{new}")

        expect(status).to eq(0)
        expect(json.dig("state", "status")).to eq("changed")
        report = json.dig("state", "report", "value")
        expect(report).to include("1.0.0 -> 2.0.0", "NEW ERA", "built from 1234567 -> abcdefa", "mints a new era")
      end
    end

    it "marks a same-version change in content, an added and a removed bluebook" do
      with_project do |dir|
        old = write_json(dir, "old.json", book(version: "1.0.0"))
        edited = book(version: "1.0.0", digest: "bbbbbbbbbb")
        edited["bluebooks"]["news"] = { "version" => "0.1.0", "shape" => ["News 1"], "digest" => "cccccccccc" }
        removed = book(version: "1.0.0")
        removed["bluebooks"]["gone"] = { "version" => "0.9.0", "shape" => ["Gone 1"], "digest" => "dddddddddd" }
        edited_path = write_json(dir, "edited.json", edited)
        removed_path = write_json(dir, "removed.json", removed)

        edit_json, = diff(dir, "old=#{old}", "new=#{edited_path}")
        remove_json, = diff(dir, "old=#{removed_path}", "new=#{old}")

        expect(edit_json.dig("state", "report", "value")).to include("SAME VERSION, DIFFERENT CONTENT", "ADDED 0.1.0")
        expect(remove_json.dig("state", "report", "value")).to include("REMOVED (was 0.9.0)")
      end
    end

    it "records unavailable, still exit 0, when a file cannot be read" do
      with_project do |dir|
        json, status = diff(dir, "old=#{File.join(dir, 'missing.json')}", "new=#{File.join(dir, 'missing.json')}")

        expect(status).to eq(0)
        expect(json.dig("state", "status")).to eq("unavailable")
        expect(json.dig("state", "report", "value")).to include("could not compare")
      end
    end

    it "flags a request that gives only one of them (exit 1), the only way it fails" do
      with_project do |dir|
        json, status = diff(dir, "old=#{write_json(dir, 'a.json', book(version: '1.0.0'))}")

        expect(status).to eq(1)
        expect(json.dig("state", "status")).to eq("flagged")
        expect(json.dig("state", "refusal", "value")).to include("old= and new= together")
      end
    end
  end

  describe "with neither, through the project's script" do
    it "records unchanged when the script reports no change" do
      with_project do |dir|
        json, status = diff(dir)

        expect(status).to eq(0)
        expect(json.dig("state", "status")).to eq("unchanged")
        expect(calls(dir)).to eq(["bluebooks-diff "])
      end
    end

    it "records changed when the script lists a change, exit 0" do
      with_project do |dir|
        json, status = diff(dir, env: { "STUB_DIFF" => "moved" })

        expect(status).to eq(0)
        expect(json.dig("state", "status")).to eq("changed")
        expect(json.dig("state", "report", "value")).to include("1.0.0 -> 1.1.0")
      end
    end

    %w[nolabel lookup first].each do |scenario|
      it "records unavailable when the script has nothing to compare (#{scenario}), exit 0" do
        with_project do |dir|
          json, status = diff(dir, env: { "STUB_DIFF" => scenario })

          expect(status).to eq(0)
          expect(json.dig("state", "status")).to eq("unavailable")
          expect(json.dig("state", "report", "value")).to start_with("==> bluebooks:")
        end
      end
    end

    it "records unavailable, not a failure, when the script ends non-zero" do
      with_project do |dir|
        json, status = diff(dir, env: { "STUB_DIFF" => "usage" })

        expect(status).to eq(0)
        expect(json.dig("state", "status")).to eq("unavailable")
        expect(json.dig("state", "report", "value")).to include("bluebook diff ended 2")
      end
    end

    it "records unavailable, with how to name one, when the project has no script" do
      with_project(script: false) do |dir|
        json, status = diff(dir)

        expect(status).to eq(0)
        expect(json.dig("state", "status")).to eq("unavailable")
        expect(json.dig("state", "report", "value")).to include("no bluebooks-diff.sh", "script=<path>")
      end
    end

    it "lists the reports that found a change" do
      with_project do |dir|
        diff(dir, env: { "STUB_DIFF" => "moved" })
        out, = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks", argv: %w[deploy bluebook_diff.changed])

        expect(JSON.parse(out).map { |row| row["status"] }).to include("changed")
      end
    end
  end
end
