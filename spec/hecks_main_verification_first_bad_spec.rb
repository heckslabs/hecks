require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/main_verification"

# A failed verification names the first bad merge among the landings since the last verified
# commit, while the shallow check is off, and adds no line while it is on.
RSpec.describe Hecks::Adapters::MainVerification, "#check" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-first-bad")) }
  let(:asked) { [] }
  let(:red) { "Failed examples:\nrspec spec/bad_spec.rb # x\n  1) Bad thing" }
  let(:outcome_class) { Hecks::Adapters::GitShallowCheck::ImpactedRun::Outcome }

  before do
    git("init", "-q", "--bare", "-b", "main", File.join(dir, "remote.git"), chdir: dir)
    git("clone", "-q", File.join(dir, "remote.git"), repo, chdir: dir)
    git("checkout", "-q", "-B", "main")
    File.write(File.join(repo, "README"), "r")
    git("add", ".")
    git("commit", "-q", "-m", "README")
    git("push", "-q", "origin", "main")
    described_class.runner = ->(argv, chdir:) { [true, chdir && argv.last && ""] }
    described_class.impacted = method(:fake_impacted)
    described_class.log_directory = File.join(dir, "logs")
  end

  after do
    described_class.runner = nil
    described_class.impacted = nil
    described_class.log_directory = nil
    FileUtils.remove_entry(dir)
  end

  def repo = File.join(dir, "repo")

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out.strip
  end

  def merge(file)
    git("checkout", "-q", "-b", "br-#{file}")
    File.write(File.join(repo, file), file)
    git("add", ".")
    git("commit", "-q", "-m", file)
    git("checkout", "-q", "main")
    git("merge", "-q", "--no-ff", "-m", "merge #{file}", "br-#{file}")
  end

  def fake_impacted(changed, _since)
    asked << changed
    raise Hecks::Adapters::ConsoleCapture::Failure, red if changed.include?("bad.txt")

    outcome_class.new(changed, [], 1, 1)
  end

  def switch(state) = Hecks::Adapters::GitShallowCheck::Switch.new(File.join(repo, ".git")).set(state)

  # Lands good, bad, good merges after a verified commit and answers the refusal of the head.
  def refusal
    Hecks::Adapters::MainIntegration::LastVerified.write(File.join(repo, ".git"), git("rev-parse", "main"))
    %w[good1.txt bad.txt good2.txt].each { |file| merge(file) }
    described_class.new.check(landed: git("rev-parse", "main"), checkout: repo)
  rescue Hecks::Adapters::ConsoleCapture::Failure => e
    e.message
  end

  it "names the one planted merge among good ones", :aggregate_failures do
    switch("off")
    text = refusal
    expect(text).to include("first bad merge ")
    expect(text).to include("merge bad.txt; spec spec/bad_spec.rb; first failing example Bad thing")
  end

  it "adds no line while the shallow check is on" do
    switch("on")
    expect(refusal).not_to include("first bad merge")
  end
end
