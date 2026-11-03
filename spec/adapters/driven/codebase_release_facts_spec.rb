require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"
require "hecks/hecks/adapters/codebase/source_tree"
require_relative "../../release/support/recording_commands"

RSpec.describe Hecks::Adapters::Codebase::ReleaseFacts do
  let(:root) { Dir.mktmpdir("hecks-release-facts") }
  let(:commands) { ReleaseSpecSupport::RecordingCommands.new(sha: sha, version: version) }
  let(:facts) { described_class.new(Hecks::Adapters::Codebase::Tree.new(root: root), commands: commands) }
  let(:found) { facts.gather("publish") }

  def version = "9.9.9"
  def sha = "a" * 40
  def failure = Hecks::Adapters::ConsoleCapture::Failure
  def tag_ref = "refs/tags/v#{version}^{commit}"

  before do
    FileUtils.mkdir_p(File.join(root, "lib/hecks"))
    FileUtils.mkdir_p(File.join(root, "packages/hecks-client"))
    File.write(File.join(root, "lib/hecks/version.rb"), %(module Hecks\n  VERSION = "#{version}".freeze\nend\n))
    File.write(File.join(root, "packages/hecks-client/package.json"), JSON.generate("version" => version))
    File.write(File.join(root, "CHANGELOG.md"), "## [#{version}] - 2026-01-01\n")
  end

  after { FileUtils.remove_entry(root) }

  it "reads every fact of a release, each as the run holds it" do
    expect(found).to include(operation: { value: "publish" }, branch: { value: "stable" }, head: { value: sha },
                             release_lane: { value: "stable" },
                             on_origin: { value: true }, clean: { value: true }, changelog: { value: true },
                             version: { value: version }, client_version: { value: version },
                             tag_state: { value: "none" }, ships_from: { path: root })
  end

  it "reads whether the commit that set the version carries the approval trailer", :aggregate_failures do
    expect(found[:approved]).to eq(value: false)

    commands.answer("git", "log", "--first-parent", "-1", "--format=%H", stdout: "#{"d" * 40}\n")
    commands.answer("git", "log", "-1", "--format=%B", "d" * 40,
                    stdout: "Release 9.9.9\n\nRelease-Approved-By: Chris Young\n")
    expect(facts.gather("publish")[:approved]).to eq(value: true)
  end

  it "does not count a trailer written by someone who is not a release owner" do
    commands.answer("git", "log", "--first-parent", "-1", "--format=%H", stdout: "#{"d" * 40}\n")
    commands.answer("git", "log", "-1", "--format=%B", "d" * 40,
                    stdout: "Release 9.9.9\n\nRelease-Approved-By: Someone\n")

    expect(facts.gather("publish")[:approved]).to eq(value: false)
  end

  it "reports a CHANGELOG heading without a date as no changelog" do
    File.write(File.join(root, "CHANGELOG.md"), "## [#{version}]\n")

    expect(found[:changelog]).to eq(value: false)
  end

  it "reports whether every ReleaseFile row names the version", :aggregate_failures do
    expect(found[:files_agree]).to eq(value: false)

    write_release_files

    expect(facts.gather("publish")[:files_agree]).to eq(value: true)
  end

  it "counts an ignored file under a packaged path as an unclean tree" do
    commands.answer("git", "status", "--porcelain", "--ignored", stdout: "!! lib/stray.rb\n")

    expect(found[:clean]).to eq(value: false)
  end

  def write_release_files
    Hecks::Vocabulary.rows("ReleaseFile").each do |row|
      path = File.join(root, row.fetch("path"))
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, release_file_text(row.fetch("path")))
    end
  end

  # The line each ReleaseFile row looks for, naming the scratch version.
  def release_file_text(path)
    case path
    when "CHANGELOG.md" then "## [#{version}] - 2026-01-01\n"
    when "lib/hecks/version.rb" then %(  VERSION = "#{version}".freeze\n)
    when "README.md" then "Current release: `#{version}`\n"
    when "Gemfile.lock" then "    hecks (#{version})\n"
    when "rust/host/HECKS_RELEASE" then "#{version}\n"
    else %({\n  "version": "#{version}"\n}\n)
    end
  end

  it "reads the IR version as a dotted number" do
    expect(found[:ir_version][:value]).to match(/\A[0-9]+[.][0-9]+[.][0-9]+\z/)
  end

  it "fetches origin before it reads" do
    found

    expect(commands.argvs).to include(%w[git fetch origin])
  end

  it "says where a tag stands: at the release commit, or elsewhere", :aggregate_failures do
    commands.answer("git", "rev-parse", "-q", "--verify", tag_ref, stdout: "#{sha}\n")
    expect(facts.gather("publish")[:tag_state]).to eq(value: "at_release_commit")

    commands.answer("git", "rev-parse", "-q", "--verify", tag_ref, stdout: "#{"c" * 40}\n")
    expect(facts.gather("publish")[:tag_state]).to eq(value: "elsewhere")
  end

  it "reports a tree that is not clean, not on the release lane, or behind origin as facts, not as refusals" do
    commands.answer("git", "status", "--porcelain", stdout: " M a\n")
    commands.answer("git", "rev-parse", "--abbrev-ref", "HEAD", stdout: "topic\n")
    commands.answer("git", "rev-parse", "origin/stable", stdout: "#{"b" * 40}\n")

    expect(found).to include(clean: { value: false }, branch: { value: "topic" }, on_origin: { value: false })
  end

  it "reads only the versions for a gem push, and starts no git", :aggregate_failures do
    found = facts.gather("publish_gem")

    expect(found.keys).to contain_exactly(:operation, :version, :client_version, :ir_version, :ships_from)
    expect(commands.calls).to be_empty
  end

  it "refuses when the fetch fails, and when a file is missing", :aggregate_failures do
    commands.answer("git", "fetch", success: false, stderr: "could not resolve host")
    expect { facts.gather("publish") }.to raise_error(failure, /git fetch origin failed/)

    FileUtils.rm_f(File.join(root, "CHANGELOG.md"))
    commands.answer("git", "fetch", success: true)
    expect { facts.gather("publish") }.to raise_error(failure, /No such file/)
  end
end
