# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/dispatching/held_ground"
require_relative "support/landing_claims_registry"

# A landing reads each rival's effective area at that moment: the files its committed branch
# changes, not the directory it was planned with and not yet narrowed by a fill.
RSpec.describe Hecks::Adapters::GitLanding::Rivals do
  let(:shell) { Hecks::Adapters::Shell.new }
  let(:repo) { Dir.mktmpdir("rivals-effective") }
  let(:dir) { "lib/hecks/hecks/adapters" }

  after { FileUtils.remove_entry(repo) }

  def git(*argv) = shell.capture("git", "-c", "user.name=t", "-c", "user.email=t@t", *argv, chdir: repo)

  def commit_files(*paths)
    paths.each do |path|
      FileUtils.mkdir_p(File.dirname(File.join(repo, path)))
      File.write(File.join(repo, path), "#{path}\n")
    end
    git("add", ".")
    git("commit", "-q", "-m", "change")
  end

  def branch(name, *paths)
    git("checkout", "-q", "-b", name)
    commit_files(*paths)
    git("checkout", "-q", "main")
  end

  def adapter
    shell = self.shell
    Object.new.tap { |git| git.define_singleton_method(:capture) { |*argv, **opts| shell.capture("git", *argv, **opts) } }
  end

  def refusal(landing, area)
    allow(Hecks::Adapters::StartedWork).to receive(:items).and_return([{ key: "held", area: area }])
    described_class.new(adapter, repo, LandingClaimsRegistry.landing_claims_registry).refusal(landing, "main")
  end

  def start_repo(*held_files)
    git("init", "-q", "-b", "main")
    commit_files("README.md")
    branch("held", *held_files)
  end

  it "does not refuse a third file in a directory the rival was planned with" do
    start_repo("#{dir}/a.rb", "#{dir}/b.rb")
    branch("third", "#{dir}/c.rb")

    expect(refusal("third", [dir])).to be_nil
  end

  it "refuses a landing of one of the rival's files" do
    start_repo("#{dir}/a.rb", "#{dir}/b.rb")
    branch("same", "#{dir}/b.rb")

    expect(refusal("same", [dir])).to include("#{dir}/b.rb")
  end

  it "keeps a file the rival's plan named beside its committed files" do
    start_repo("#{dir}/a.rb")
    branch("named", "#{dir}/n.rb")

    expect(refusal("named", [dir, "#{dir}/n.rb"])).to include("#{dir}/n.rb")
  end

  it "holds a rival with no commits to its planned directory" do
    start_repo
    branch("third", "#{dir}/c.rb")

    expect(refusal("third", [dir])).to include(dir)
  end
end
