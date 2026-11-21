require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/bisect_log_guard"

# A fix for a red train or a red main lands only once its bisect is logged: a search, or an
# obvious-from-the-failure finding that quotes the failure line. Each example reads a throwaway
# directory standing in for a repository's git directory.
RSpec.describe Hecks::Adapters::BisectLogGuard do
  let(:git_dir) { Dir.mktmpdir("hecks-bisect-log") }
  let(:marker) { Hecks::Adapters::BisectLogMarker.new(git_dir) }

  after { FileUtils.remove_entry(git_dir) }

  it "refuses a red train's fix before any bisect is logged, naming the missing bisect" do
    expect { described_class.new(git_dir).landing!("red-train-9") }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /red-train-9 has no bisect log/)
  end

  it "refuses a red main's fix, with or without the QA lead, until it is logged", :aggregate_failures do
    expect { described_class.new(git_dir).landing!("qa/red-main-3") }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /red-main-3 has no bisect log/)
    marker.record!(work: "red-main-3", kind: "bisect", finding: "red at the base")
    expect { described_class.new(git_dir).landing!("qa/red-main-3") }.not_to raise_error
  end

  it "passes a fix whose search is logged" do
    marker.record!(work: "red-train-9", kind: "bisect", finding: "culprit abc")
    expect { described_class.new(git_dir).landing!("red-train-9") }.not_to raise_error
  end

  it "passes an obvious finding that quotes the failure line" do
    marker.record!(work: "red-train-9", kind: "obvious", quote: "expected a banner, got none")
    expect { described_class.new(git_dir).landing!("red-train-9") }.not_to raise_error
  end

  it "refuses an obvious finding that quotes nothing" do
    marker.record!(work: "red-train-9", kind: "obvious", quote: " ")
    expect { described_class.new(git_dir).landing!("red-train-9") }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure)
  end

  it "asks nothing of any other branch" do
    expect { described_class.new(git_dir).landing!("a-feature") }.not_to raise_error
  end
end
