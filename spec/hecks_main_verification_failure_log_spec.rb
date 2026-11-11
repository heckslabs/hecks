require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/main_verification"

# A verification whose spec fails names the spec file, the first failing example and a kept log,
# so the failure can be read after the clean copy is gone. The repository and the log directory
# are throwaway ones and the checks are a fake runner.
RSpec.describe Hecks::Adapters::MainVerification do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-main-verification")) }
  let(:logs) { File.join(dir, "verification-logs") }
  let(:checks) { [["quick gate", %w[gate]], ["specs 1/1", %w[specs]]] }

  def failed_spec_output
    <<~OUT
      Failures:

        1) Widget spins when pushed
           Failure/Error: expect(1).to eq(2)

      Failed examples:

      rspec ./spec/widget_spec.rb:12 # Widget spins when pushed
    OUT
  end

  before do
    git("init", "-q", "-b", "main", dir)
    git("commit", "-q", "--allow-empty", "-m", "start")
    allow(Hecks::Adapters::MainIntegration::Checks).to receive(:new)
      .and_return(instance_double(Hecks::Adapters::MainIntegration::Checks, all: checks))
    described_class.runner = ->(argv, **) { argv == %w[gate] ? [true, "green"] : [false, failed_spec_output] }
    described_class.log_directory = logs
  end

  after do
    described_class.runner = nil
    described_class.log_directory = nil
    FileUtils.remove_entry(dir)
  end

  def git(*args)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: dir)
    raise out unless status.success?

    out
  end

  def refusal
    described_class.new.check(landed: git("rev-parse", "main").strip, checkout: dir)
    ""
  rescue Hecks::Adapters::ConsoleCapture::Failure => e
    e.message
  end

  def logged_path = refusal.lines.first[/log (\S+)/, 1]

  it "names the failing spec file in the first line" do
    expect(refusal.lines.first).to include("failed verification: specs 1/1", "spec ./spec/widget_spec.rb")
  end

  it "names the first failing example in the first line" do
    expect(refusal.lines.first).to include("first failing example Widget spins when pushed")
  end

  it "keeps a log holding what the failing check printed", :aggregate_failures do
    expect(File.file?(logged_path)).to be(true)
    expect(File.read(logged_path)).to include("spec ./spec/widget_spec.rb:12")
  end

  it "keeps only the newest 20 logs", :aggregate_failures do
    22.times { refusal }
    expect(Dir.children(logs).size).to eq(20)
    expect(File.file?(logged_path)).to be(true)
  end

  it "bounds a log to its last 400 lines" do
    described_class.runner = ->(*, **) { [false, (1..500).map { |n| "line #{n}\n" }.join] }
    refusal
    expect(File.read(Dir.glob(File.join(logs, "*")).first)).not_to include("line 100\n")
  end
end
