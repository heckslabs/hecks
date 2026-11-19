require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/main_verification"
require_relative "support/hecks_launcher_stub"

# A landing in a project built on the hecks gem starts a main-integration run too, but the
# project's commit holds no hecks launcher: its verification answers `superseded` without a
# check, before main is read, so the run ends instead of failing the quick gate in a copy that
# cannot run it. The repository is a throwaway one and the checks are a fake runner.
RSpec.describe Hecks::Adapters::MainVerification, "#check of a project checkout" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-main-foreign")) }
  let(:ran) { [] }

  before do
    git("init", "-q", "-b", "main", dir)
    checks = instance_double(Hecks::Adapters::MainIntegration::Checks, all: [["quick gate", %w[gate]]])
    allow(Hecks::Adapters::MainIntegration::Checks).to receive(:new).and_return(checks)
    described_class.runner = ->(argv, chdir:) { (ran << argv.first) && [true, chdir && ""] }
    described_class.log_directory = File.join(dir, "verification-logs")
  end

  after do
    described_class.runner = nil
    described_class.log_directory = nil
    FileUtils.remove_entry(dir)
  end

  def git(*args)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: dir)
    raise out unless status.success?

    out.strip
  end

  def landed(file)
    File.write(File.join(dir, file), file)
    git("add", ".")
    git("commit", "-q", "-m", file)
    git("rev-parse", "HEAD")
  end

  def verify(sha) = described_class.new.check(landed: sha, checkout: dir)

  it "answers superseded, naming the checkout, and runs no check", :aggregate_failures do
    answer = verify(landed("README"))
    expect(answer[:outcome][:value]).to eq("superseded")
    expect(answer[:report][:value]).to include("landed in #{dir}", "holds no exe/hecks", "no check run")
    expect(ran).to be_empty
  end

  it "answers superseded even when the checkout has no main branch" do
    git("checkout", "-q", "-b", "trunk")
    expect(verify(landed("README"))[:outcome][:value]).to eq("superseded")
  end

  it "answers superseded when the launcher is in the working tree but not in the commit" do
    sha = landed("README")
    HecksLauncherStub.place(dir)
    expect(verify(sha)[:outcome][:value]).to eq("superseded")
  end

  it "checks a commit that holds the launcher", :aggregate_failures do
    HecksLauncherStub.place(dir)
    expect(verify(landed("README"))[:outcome][:value]).to eq("verified")
    expect(ran).to eq(%w[gate])
  end
end
