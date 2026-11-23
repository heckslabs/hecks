# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/dispatching/held_ground"
require_relative "landing_claims_registry"

# A throwaway git repository with one branch per file and a Rivals check against a held area.
module NarrowedAreaWorld
  def shell = @shell ||= Hecks::Adapters::Shell.new

  def repo = @repo ||= Dir.mktmpdir("areas-narrowed")

  def git(*argv) = shell.capture("git", "-c", "user.name=t", "-c", "user.email=t@t", *argv, chdir: repo)

  def git_adapter
    shell = self.shell
    Object.new.tap { |git| git.define_singleton_method(:capture) { |*argv, **opts| shell.capture("git", *argv, **opts) } }
  end

  def init_repo
    git("init", "-q", "-b", "main")
    File.write(File.join(repo, "README.md"), "r\n")
    git("add", ".")
    git("commit", "-q", "-m", "init")
  end

  def landing(name, path)
    git("checkout", "-q", "-b", name)
    FileUtils.mkdir_p(File.dirname(File.join(repo, path)))
    File.write(File.join(repo, path), "x\n")
    git("add", ".")
    git("commit", "-q", "-m", name)
    git("checkout", "-q", "main")
  end

  def rivals_refusal(name, held_area)
    allow(Hecks::Adapters::StartedWork).to receive(:items).and_return([{ key: "held", area: held_area }])
    registry = LandingClaimsRegistry.landing_claims_registry
    Hecks::Adapters::GitLanding::Rivals.new(git_adapter, repo, registry).refusal(name, "main")
  end
end
