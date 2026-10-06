require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"
require_relative "release/support/recording_commands"

# Publishing through the launcher: `hecks publish` and `hecks publish_gem` are journaled runs of
# PublishingRun. The facts the Git adapter surveys are judged by the givens of `Clear`, only a
# cleared run is carried out, and a real run advances the root Release through tagged, published
# and verified. Every process is a recorder over a scratch checkout: nothing is tagged, pushed,
# published or fetched.
RSpec.describe "publishing a release" do
  let(:version) { "9.9.9" }
  let(:sha) { "a" * 40 }
  let(:root) { Dir.mktmpdir("hecks-publishing-spec") }
  let(:commands) { ReleaseSpecSupport::RecordingCommands.new(sha: sha, version: version) }

  def build_checkout
    FileUtils.mkdir_p(File.join(root, "lib/hecks"))
    FileUtils.mkdir_p(File.join(root, "packages/hecks-client"))
    File.write(File.join(root, "hecks.gemspec"), "")
    File.write(File.join(root, "lib/hecks/version.rb"), %(module Hecks\n  VERSION = "#{version}".freeze\nend\n))
    FileUtils.mkdir_p(File.join(root, "rust/host"))
    File.write(File.join(root, "rust/host/HECKS_RELEASE"), "#{version}\n")
    File.write(File.join(root, "packages/hecks-client/package.json"),
               JSON.generate("name" => "@hecks/client", "version" => version))
    File.write(File.join(root, "CHANGELOG.md"), "# Changelog\n\n## [#{version}] - 2026-01-01\n")
  end

  before do
    build_checkout
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
    Hecks::Adapters::Codebase::Tree.root = root
    Hecks::Adapters::Codebase::Publishing.commands = commands
    Hecks::Adapters::Codebase::Publishing.release_options = { pause: ->(_) {}, now: -> { 0 } }
  end

  after do
    Hecks::Adapters::Codebase::Tree.root = nil
    Hecks::Adapters::Codebase::Publishing.commands = nil
    Hecks::Adapters::Codebase::Publishing.release_options = nil
    FileUtils.remove_entry(root)
  end

  def launch(*argv)
    Hecks::Doors::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  end

  def outcome(run) = launch("publishing_run.publishing_outcome", "run=#{run}").first

  def registry_lists_the_gem_after_the_push!
    commands.on_run("op", "run", "--env-file=release/gem_push.env") do
      commands.answer("curl", "-fsS", stdout: JSON.generate([{ "number" => version }]))
    end
  end

  describe "hecks publish" do
    it "is the dry run without --confirm: it reports, and tags, pushes and publishes nothing" do
      _, status = launch("publishing_run.publish", "run=dry", "--gem-only")
      out = outcome("dry")

      expect(status).to eq(0)
      expect(out).to include('"status": "completed"', "Dry run complete; nothing was tagged, pushed or published.")
      expect(commands.runs.map(&:argv)).not_to include(include("push"))
      expect(commands.ran?("git", "tag")).to be(false)
      expect(launch("release.shipped").first).not_to include(version)
    end

    it "tags, publishes and verifies the root Release when confirmed" do
      registry_lists_the_gem_after_the_push!

      _, status = launch("publishing_run.publish", "run=real", "--gem-only", "--confirm")
      out = outcome("real")

      expect(status).to eq(0)
      expect(out).to include('"status": "completed"', "Released hecks #{version}.")
      expect(commands.ran?("git", "tag", "-a", "v#{version}")).to be(true)
      expect(commands.ran?("git", "push", "origin", "v#{version}")).to be(true)
      expect(launch("release.shipped").first).to include(version)
    end

    it "records the steps taken before a failure, and a rerun that finds nothing left verifies" do
      registry_lists_the_gem_after_the_push!
      commands.fail_run("op", "run", "--env-file=#{File.join(root, "release/npm_publish.env")}")

      launch("publishing_run.publish", "run=partial", "--npm-local", "--confirm")

      expect(outcome("partial")).to include('"status": "faulted"', "npm publish failed")
      expect(launch("release.shipped").first).not_to include(version)

      rerun = ReleaseSpecSupport::RecordingCommands.new(sha: sha, version: version)
      rerun.answer("curl", "-fsS", stdout: JSON.generate([{ "number" => version }]))
      rerun.answer("npm", "view", stdout: "#{version}\n")
      rerun.answer("git", "rev-parse", "-q", "--verify", "refs/tags/v#{version}^{commit}", stdout: "#{sha}\n")
      rerun.answer("git", "ls-remote", stdout: "#{sha}\trefs/tags/v#{version}^{}\n")
      Hecks::Adapters::Codebase::Publishing.commands = rerun

      launch("publishing_run.publish", "run=rerun", "--npm-local", "--confirm")

      expect(outcome("rerun")).to include('"status": "completed"', "Nothing to publish")
      expect(launch("release.shipped").first).to include(version)
    end

    it "refuses to release from a branch that is not main, and does nothing" do
      commands.answer("git", "rev-parse", "--abbrev-ref", "HEAD", stdout: "feature\n")

      out, = launch("publishing_run.publish", "run=off-main", "--gem-only", "--confirm")

      expect(out).to include("a release is cut from main")
      expect(commands.runs).to be_empty
    end

    it "refuses when main is not origin/main" do
      commands.answer("git", "rev-parse", "origin/main", stdout: "#{"b" * 40}\n")

      out, = launch("publishing_run.publish", "run=behind", "--gem-only", "--confirm")

      expect(out).to include("main is origin/main")
      expect(commands.runs).to be_empty
    end

    it "refuses a dirty working tree" do
      commands.answer("git", "status", "--porcelain", stdout: " M lib/hecks/version.rb\n")

      out, = launch("publishing_run.publish", "run=dirty", "--gem-only", "--confirm")

      expect(out).to include("the working tree is clean")
    end

    it "--wait exits 1 on a dirty tree and shows the refused reaction" do
      commands.answer("git", "status", "--porcelain", stdout: " M lib/hecks/version.rb\n")

      out, status = launch("publishing_run.publish", "run=dirty-wait", "--wait")

      expect(status).to eq(1)
      expect(out).to include("refused_reactions", "the working tree is clean")
    end

    it "without --wait still exits 0 on a dirty tree (the refusal is only reported)" do
      commands.answer("git", "status", "--porcelain", stdout: " M lib/hecks/version.rb\n")

      out, status = launch("publishing_run.publish", "run=dirty-nowait")

      expect(status).to eq(0)
      expect(out).to include("refused_reactions")
    end

    it "refuses a client package at another version" do
      File.write(File.join(root, "packages/hecks-client/package.json"),
                 JSON.generate("name" => "@hecks/client", "version" => "9.9.8"))

      out, = launch("publishing_run.publish", "run=client", "--gem-only", "--confirm")

      expect(out).to include("the client package is at the gem's version")
    end

    it "refuses a changelog with no heading for the version" do
      File.write(File.join(root, "CHANGELOG.md"), "# Changelog\n\n## [Unreleased]\n")

      out, = launch("publishing_run.publish", "run=changelog", "--gem-only", "--confirm")

      expect(out).to include("CHANGELOG.md has a heading for the version")
    end

    it "refuses a tag that points at another commit" do
      commands.answer("git", "rev-parse", "-q", "--verify", "refs/tags/v#{version}^{commit}", stdout: "#{"c" * 40}\n")

      out, = launch("publishing_run.publish", "run=tag", "--gem-only", "--confirm")

      expect(out).to include("a tag for the version points at the release commit")
    end

    it "refuses contradicting flags before anything is started" do
      launch("publishing_run.publish", "run=flags", "--gem-only", "--npm-only", "--confirm")

      expect(outcome("flags")).to include('"status": "faulted"', "cannot be combined")
      expect(commands.runs).to be_empty
    end
  end

  describe "hecks publish_gem" do
    it "builds the gem and deletes it, pushing nothing, without --confirm" do
      _, status = launch("publishing_run.publish_gem", "run=gem-dry")
      out = outcome("gem-dry")

      expect(status).to eq(0)
      expect(out).to include("dry run, built hecks-#{version}.gem")
      expect(commands.ran?("gem", "build", "hecks.gemspec")).to be(true)
      expect(commands.argvs.flatten).not_to include("push")
    end

    it "pushes the gem through the vault when confirmed" do
      _, status = launch("publishing_run.publish_gem", "run=gem-real", "--confirm")
      out = outcome("gem-real")

      expect(status).to eq(0)
      expect(out).to include("Released hecks #{version}.")
      expect(commands.ran?("op", "run", "--env-file=release/gem_push.env", "--", "gem", "push")).to be(true)
    end

    it "refuses a client package at another version" do
      File.write(File.join(root, "packages/hecks-client/package.json"),
                 JSON.generate("name" => "@hecks/client", "version" => "9.9.8"))

      out, = launch("publishing_run.publish_gem", "run=gem-client", "--confirm")

      expect(out).to include("the client package is at the gem's version")
      expect(commands.runs).to be_empty
    end
  end
end
