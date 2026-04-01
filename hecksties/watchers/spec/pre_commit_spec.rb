require "spec_helper"

RSpec.describe HecksWatchers::PreCommit do
  let(:project_root) { Dir.pwd }
  let(:logger) { instance_double(HecksWatchers::Logger, log: nil) }
  subject { described_class.new(project_root: project_root, logger: logger) }

  let(:cross_require) { instance_double(HecksWatchers::CrossRequire) }
  let(:file_size) { instance_double(HecksWatchers::FileSize) }
  let(:doc_reminder) { instance_double(HecksWatchers::DocReminder) }
  let(:spec_coverage) { instance_double(HecksWatchers::SpecCoverage) }
  before do
    allow(HecksWatchers::CrossRequire).to receive(:new).and_return(cross_require)
    allow(HecksWatchers::FileSize).to receive(:new).and_return(file_size)
    allow(HecksWatchers::DocReminder).to receive(:new).and_return(doc_reminder)
    allow(HecksWatchers::SpecCoverage).to receive(:new).and_return(spec_coverage)

    allow(file_size).to receive(:call).and_return([])
    allow(doc_reminder).to receive(:call).and_return([])
    allow(spec_coverage).to receive(:call).and_return([])
  end

  context "when no blockers" do
    before { allow(cross_require).to receive(:call).and_return([]) }

    it "returns true" do
      expect(subject.call).to be true
    end

    it "runs all advisory watchers" do
      subject.call
      expect(file_size).to have_received(:call)
      expect(doc_reminder).to have_received(:call)
      expect(spec_coverage).to have_received(:call)
    end
  end

  context "when cross-require violations found" do
    before { allow(cross_require).to receive(:call).and_return(["violation"]) }

    it "returns false" do
      expect(subject.call).to be false
    end

    it "still runs advisory watchers" do
      subject.call
      expect(file_size).to have_received(:call)
    end
  end
end
