require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/main_verification"

# A verification that fails refuses naming each failed check and keeping the last lines of what
# each printed, so the run parked in needs_human says why. The repository is a throwaway one and
# the checks are a fake runner: nothing runs a launcher command.
RSpec.describe Hecks::Adapters::MainVerification do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-main-verification")) }

  before do
    git("init", "-q", "-b", "main", dir)
    git("commit", "-q", "--allow-empty", "-m", "start")
    checks = instance_double(Hecks::Adapters::MainIntegration::Checks, all: CHECKS)
    allow(Hecks::Adapters::MainIntegration::Checks).to receive(:new).and_return(checks)
    described_class.runner = method(:fake_run)
    described_class.log_directory = File.join(dir, "verification-logs")
  end

  after do
    described_class.runner = nil
    described_class.log_directory = nil
    FileUtils.remove_entry(dir)
  end

  CHECKS = [["quick gate", %w[gate]], ["specs 1/1", %w[specs]], ["corpus", %w[corpus]]].freeze unless defined?(CHECKS)

  def git(*args)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: dir)
    raise out unless status.success?

    out
  end

  def numbered(name) = (1..100).map { |n| "#{name} line #{n}\n" }.join

  def fake_run(argv, chdir:)
    return [true, numbered("corpus")] if argv == %w[corpus]

    [false, numbered(argv.first)]
  end

  def refusal
    described_class.new.check(landed: git("rev-parse", "main").strip, checkout: dir)
    ""
  rescue Hecks::Adapters::ConsoleCapture::Failure => e
    e.message
  end

  it "names every failed check in its first line" do
    expect(refusal.lines.first).to include("failed verification: quick gate, specs 1/1")
  end

  it "keeps the last 60 lines of each failed check's output, line by line", :aggregate_failures do
    text = refusal
    expect(text).to include("gate line 41\n", "gate line 100", "specs line 41\n", "specs line 100")
    expect(text).not_to include("gate line 40\n", "specs line 40\n")
  end

  it "leaves out what a passed check printed" do
    expect(refusal).not_to include("corpus line")
  end
end
