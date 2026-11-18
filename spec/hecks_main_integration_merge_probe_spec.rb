require "spec_helper"
require "hecks/hecks/adapters/main_verification"

# The search for the first bad merge probes the failure, not each merge's own specs: the failing
# spec files run at the merge, so the answer is red from the breaking merge onward and the binary
# search cannot skip it.
RSpec.describe Hecks::Adapters::MainIntegration::MergeProbe do
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }
  let(:merges) { %w[a b c].map { |sha| { sha: sha, subject: "merge #{sha}", paths: ["#{sha}.rb"] } } }

  # A probe whose copies are named for their commit; the runner is red at the `red` commits.
  def probe_with(red)
    repository = instance_double(Hecks::Adapters::MainIntegration::Repository)
    allow(repository).to receive(:clean_copy) { |sha, &block| block.call(sha) }
    runner = ->(copy, _files) { raise failure, "failing spec: spec/x_spec.rb # boom" if red.include?(copy) }
    described_class.new(repository, failing: ["spec/x_spec.rb"], runner: runner)
  end

  def search(red)
    @search = Hecks::Adapters::MainIntegration::FirstBad.new(merges, probe: probe_with(red))
    @search.call
  end

  describe "the search over its probes" do
    it "finds the first merge when it breaks a spec the later merges do not touch" do
      expect(search(%w[a b c])[:sha]).to eq("a")
    end

    it "finds the middle merge when it is the one that breaks the specs" do
      expect(search(%w[b c])[:sha]).to eq("b")
    end

    it "answers nil, saying why, when no single merge is red", :aggregate_failures do
      expect(search([])).to be_nil
      expect(@search.reason).to eq("no merge in the range turns the failing specs red")
    end

    it "names the failing spec a red probe printed" do
      expect(search(%w[c])[:finding]).to eq(spec: "spec/x_spec.rb")
    end
  end

  describe "#red_at?" do
    it "reads the base as red when the failing specs are red there too" do
      expect(probe_with(%w[base]).red_at?("base")).to be(true)
    end

    it "reads the base as green when the failing specs pass there" do
      expect(probe_with(%w[c]).red_at?("base")).to be(false)
    end
  end
end
