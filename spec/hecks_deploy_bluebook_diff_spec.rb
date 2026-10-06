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

  # A scratch project for each example, named by `dir`: it holds the stand-in script unless the
  # example is tagged `no_script`.
  around do |example|
    Dir.mktmpdir do |scratch|
      FileUtils.mkdir_p(File.join(scratch, "platform"))
      write_stub_script(scratch) unless example.metadata[:no_script]
      @dir = scratch
      example.run
    end
  end

  attr_reader :dir

  def write_stub_script(scratch)
    path = File.join(scratch, "platform", "bluebooks-diff.sh")
    File.write(path, DIFF_SCRIPT_STUB)
    File.chmod(0o755, path)
  end

  def book(version:, shape: ["Cms 1"], digest: "aaaaaaaaaa", commit: "1234567890")
    { "bluebooks"  => { "cms" => { "version" => version, "shape" => shape, "digest" => digest } },
      "built_from" => { "commit" => commit, "dirty" => false } }
  end

  def edited_book
    book(version: "1.0.0", digest: "bbbbbbbbbb").tap do |edited|
      edited["bluebooks"]["news"] = { "version" => "0.1.0", "shape" => ["News 1"], "digest" => "cccccccccc" }
    end
  end

  def removed_book
    book(version: "1.0.0").tap do |removed|
      removed["bluebooks"]["gone"] = { "version" => "0.9.0", "shape" => ["Gone 1"], "digest" => "dddddddddd" }
    end
  end

  def write_json(name, data)
    File.join(dir, name).tap { |path| File.write(path, JSON.generate(data)) }
  end

  def diff(*argv, env: {})
    settings = { "STUB_DIR" => dir }.merge(env)
    saved = ENV.to_h.slice(*settings.keys)
    ENV.update(settings)
    out, status = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                               argv: ["deploy", "bluebook_diff.run", dir, *argv, "--wait"])
    [JSON.parse(out), status]
  ensure
    settings.each_key { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  def diff_files(old, new) = diff("old=#{write_json("old.json", old)}", "new=#{write_json("new.json", new)}")

  def report_of(json) = json.dig("state", "report", "value")

  def calls
    path = File.join(dir, "calls.log")
    File.exist?(path) ? File.readlines(path, chomp: true) : []
  end

  it "is declared in the Deploy chapter, with the port it asks" do
    commands = @hecks.registry.bluebook("Deploy").aggregate("BluebookDiff").commands.map(&:hecks_name)

    expect(commands).to eq(%w[Run Match Differ Withhold Flag])
  end

  describe "with old= and new=" do
    it "records unchanged for two identical outputs and exits 0", :aggregate_failures do
      json, status = diff_files(book(version: "1.0.0"), book(version: "1.0.0"))

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("unchanged")
    end

    it "reports the identical outputs and runs no script", :aggregate_failures do
      json, = diff_files(book(version: "1.0.0"), book(version: "1.0.0"))

      expect(report_of(json)).to include("cms", "unchanged", "no bluebook changes.")
      expect(calls).to be_empty
    end

    it "records changed, exits 0, when the version and the shape both moved", :aggregate_failures do
      json, status = diff_files(book(version: "1.0.0"), book(version: "2.0.0", shape: ["Cms 2"], commit: "abcdefabcdef"))

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("changed")
    end

    it "marks a new era when the version and the shape both moved" do
      json, = diff_files(book(version: "1.0.0"), book(version: "2.0.0", shape: ["Cms 2"], commit: "abcdefabcdef"))

      expect(report_of(json)).to include("1.0.0 -> 2.0.0", "NEW ERA", "built from 1234567 -> abcdefa", "mints a new era")
    end

    it "marks a same-version change in content, and an added bluebook" do
      json, = diff_files(book(version: "1.0.0"), edited_book)

      expect(report_of(json)).to include("SAME VERSION, DIFFERENT CONTENT", "ADDED 0.1.0")
    end

    it "marks a removed bluebook" do
      json, = diff_files(removed_book, book(version: "1.0.0"))

      expect(report_of(json)).to include("REMOVED (was 0.9.0)")
    end

    it "records unavailable, still exit 0, when a file cannot be read", :aggregate_failures do
      json, status = diff("old=#{File.join(dir, "missing.json")}", "new=#{File.join(dir, "missing.json")}")

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("unavailable")
      expect(report_of(json)).to include("could not compare")
    end

    it "flags a request that gives only one of them (exit 1), the only way it fails", :aggregate_failures do
      json, status = diff("old=#{write_json("a.json", book(version: "1.0.0"))}")

      expect(status).to eq(1)
      expect(json.dig("state", "status")).to eq("flagged")
      expect(json.dig("state", "refusal", "value")).to include("old= and new= together")
    end
  end

  describe "with neither, through the project's script" do
    it "records unchanged when the script reports no change", :aggregate_failures do
      json, status = diff

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("unchanged")
      expect(calls).to eq(["bluebooks-diff "])
    end

    it "records changed when the script lists a change, exit 0", :aggregate_failures do
      json, status = diff(env: { "STUB_DIFF" => "moved" })

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("changed")
      expect(report_of(json)).to include("1.0.0 -> 1.1.0")
    end

    ["nolabel", "lookup", "first"].each do |scenario|
      it "records unavailable when the script has nothing to compare (#{scenario}), exit 0", :aggregate_failures do
        json, status = diff(env: { "STUB_DIFF" => scenario })

        expect(status).to eq(0)
        expect(json.dig("state", "status")).to eq("unavailable")
        expect(report_of(json)).to start_with("==> bluebooks:")
      end
    end

    it "records unavailable, not a failure, when the script ends non-zero", :aggregate_failures do
      json, status = diff(env: { "STUB_DIFF" => "usage" })

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("unavailable")
      expect(report_of(json)).to include("bluebook diff ended 2")
    end

    it "records unavailable, with how to name one, when the project has no script", :aggregate_failures, :no_script do
      json, status = diff

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("unavailable")
      expect(report_of(json)).to include("no bluebooks-diff.sh", "script=<path>")
    end

    it "lists the reports that found a change" do
      diff(env: { "STUB_DIFF" => "moved" })
      out, = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks", argv: %w[deploy bluebook_diff.changed])

      expect(JSON.parse(out).map { |row| row["status"] }).to include("changed")
    end
  end
end
