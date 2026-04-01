require "spec_helper"

RSpec.describe HecksWatchers::DocReminder do
  let(:project_root) { Dir.pwd }
  let(:logger) { instance_double(HecksWatchers::Logger, log: nil) }
  subject { described_class.new(project_root: project_root, logger: logger) }

  before do
    allow(subject).to receive(:staged_files).and_return(staged)
  end

  context "when no lib files are staged" do
    let(:staged) { ["README.md"] }

    it "returns empty" do
      expect(subject.call).to eq([])
    end
  end

  context "when lib files staged without FEATURES.md" do
    let(:staged) { ["hecks_cli/lib/hecks/cli/new.rb"] }

    before do
      allow(Dir).to receive(:chdir).and_yield
      allow(subject).to receive(:`).with("git diff --cached --diff-filter=A --name-only")
        .and_return("hecks_cli/lib/hecks/cli/new.rb\n")
    end

    it "warns about FEATURES.md" do
      result = subject.call
      expect(result.any? { |w| w.include?("FEATURES.md") }).to be true
    end
  end

  context "when DSL builder files staged without reference doc" do
    let(:staged) { ["bluebook/lib/hecks/dsl/aggregate_builder.rb"] }

    before do
      allow(Dir).to receive(:chdir).and_yield
      allow(subject).to receive(:`).with("git diff --cached --diff-filter=A --name-only")
        .and_return("")
    end

    it "warns about dsl_reference.md" do
      result = subject.call
      expect(result.any? { |w| w.include?("dsl_reference.md") }).to be true
    end
  end

  context "when lib files staged without CHANGELOG" do
    let(:staged) { ["hecks_cli/lib/hecks/cli/existing.rb"] }

    before do
      allow(Dir).to receive(:chdir).and_yield
      allow(subject).to receive(:`).with("git diff --cached --diff-filter=A --name-only")
        .and_return("")
    end

    it "warns about missing changelog" do
      result = subject.call
      expect(result.any? { |w| w.include?("hecks_cli/CHANGELOG.md") }).to be true
    end
  end
end
