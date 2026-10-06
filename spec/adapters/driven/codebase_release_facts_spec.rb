require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"
require "hecks/hecks/adapters/codebase/source_tree"
require_relative "../../release/support/recording_commands"

RSpec.describe Hecks::Adapters::Codebase::ReleaseFacts do
  let(:version) { "9.9.9" }
  let(:sha) { "a" * 40 }
  let(:root) { Dir.mktmpdir("hecks-release-facts") }
  let(:commands) { ReleaseSpecSupport::RecordingCommands.new(sha: sha, version: version) }
  let(:facts) { described_class.new(Hecks::Adapters::Codebase::Tree.new(root: root), commands: commands) }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }
  let(:tag_ref) { "refs/tags/v#{version}^{commit}" }

  before do
    FileUtils.mkdir_p(File.join(root, "lib/hecks"))
    FileUtils.mkdir_p(File.join(root, "packages/hecks-client"))
    File.write(File.join(root, "lib/hecks/version.rb"), %(module Hecks\n  VERSION = "#{version}".freeze\nend\n))
    File.write(File.join(root, "packages/hecks-client/package.json"), JSON.generate("version" => version))
    File.write(File.join(root, "CHANGELOG.md"), "## [#{version}] - 2026-01-01\n")
  end

  after { FileUtils.remove_entry(root) }

  it "reads every fact of a release, each as the run holds it, after fetching origin" do
    found = facts.gather("publish")

    expect(found).to include(operation: { value: "publish" }, branch: { value: "main" }, head: { value: sha },
                             on_origin: { value: true }, clean: { value: true }, changelog: { value: true },
                             version: { value: version }, client_version: { value: version },
                             tag_state: { value: "none" }, ships_from: { path: root })
    expect(found[:ir_version][:value]).to match(/\A[0-9]+[.][0-9]+[.][0-9]+\z/)
    expect(commands.argvs).to include(%w[git fetch origin])
  end

  it "says where a tag stands: at the release commit, or elsewhere" do
    commands.answer("git", "rev-parse", "-q", "--verify", tag_ref, stdout: "#{sha}\n")
    expect(facts.gather("publish")[:tag_state]).to eq(value: "at_release_commit")

    commands.answer("git", "rev-parse", "-q", "--verify", tag_ref, stdout: "#{"c" * 40}\n")
    expect(facts.gather("publish")[:tag_state]).to eq(value: "elsewhere")
  end

  it "reports a tree that is not clean, not on main, or behind origin as facts, not as refusals" do
    commands.answer("git", "status", "--porcelain", stdout: " M a\n")
    commands.answer("git", "rev-parse", "--abbrev-ref", "HEAD", stdout: "topic\n")
    commands.answer("git", "rev-parse", "origin/main", stdout: "#{"b" * 40}\n")

    found = facts.gather("publish")

    expect(found).to include(clean: { value: false }, branch: { value: "topic" }, on_origin: { value: false })
  end

  it "reads only the versions for a gem push, and starts no git" do
    found = facts.gather("publish_gem")

    expect(found.keys).to contain_exactly(:operation, :version, :client_version, :ir_version, :ships_from)
    expect(commands.calls).to be_empty
  end

  it "refuses when the fetch fails, and when a file is missing" do
    commands.answer("git", "fetch", success: false, stderr: "could not resolve host")
    expect { facts.gather("publish") }.to raise_error(failure, /git fetch origin failed/)

    FileUtils.rm_f(File.join(root, "CHANGELOG.md"))
    commands.answer("git", "fetch", success: true)
    expect { facts.gather("publish") }.to raise_error(failure, /No such file/)
  end
end
