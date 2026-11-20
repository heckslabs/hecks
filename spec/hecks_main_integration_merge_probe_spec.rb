require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/main_verification"

# The search for the first bad merge probes the failure, not each merge's own specs: the failing
# specs run at the merge and at its first parent, whatever the merge's own paths touch, and once
# a red run names the failing example the probes run that example alone.
RSpec.describe Hecks::Adapters::MainIntegration::MergeProbe do
  def failure = Hecks::Adapters::ConsoleCapture::Failure

  def merges = %w[a b c].map { |sha| { sha: sha, subject: "merge #{sha}", paths: ["#{sha}.rb"] } }

  def parents = { "a" => "base", "b" => "a", "c" => "b" }

  # A probe whose copies are named for their commit; the runner is red at the `red` commits.
  def probe_with(red)
    runner = ->(copy, _files) { raise failure, "failing spec: spec/x_spec.rb # boom" if red.include?(copy) }
    described_class.new(repository, failing: ["spec/x_spec.rb"], runner: runner)
  end

  def repository
    instance_double(Hecks::Adapters::MainIntegration::Repository).tap do |held|
      allow(held).to receive(:clean_copy) { |sha, &block| block.call(sha) }
      allow(held).to receive(:first_parent) { |sha| parents[sha] }
    end
  end

  def search_of(red) = Hecks::Adapters::MainIntegration::FirstBad.new(merges, probe: probe_with(red))

  describe "the search over its probes" do
    it "finds the first merge when it breaks a spec the later merges do not touch" do
      expect(search_of(%w[a b c]).call[:sha]).to eq("a")
    end

    it "finds the middle merge when it is the one that breaks the specs" do
      expect(search_of(%w[b c]).call[:sha]).to eq("b")
    end

    it "answers nil, saying why, when no single merge is red", :aggregate_failures do
      search = search_of([])
      expect(search.call).to be_nil
      expect(search.reason).to eq("no merge in the range turns the failing specs red")
    end

    it "names the failing spec a red probe printed" do
      expect(search_of(%w[c]).call[:finding]).to eq(spec: "spec/x_spec.rb")
    end

    it "names no merge when the specs are red at the oldest merge's first parent too" do
      expect(search_of(%w[base a b c]).call).to be_nil
    end
  end

  describe "#before" do
    it "reads the merge's first parent" do
      expect(probe_with(%w[a]).before(sha: "b").first).to be(false)
    end

    it "is green for a merge that has no first parent" do
      expect(probe_with(%w[a]).before(sha: "root")).to eq([true, nil])
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

  # The default runner of a probe: whole spec files until a red run names the failing example,
  # then that example alone. The launcher is a stand-in.
  describe Hecks::Adapters::MainIntegration::MergeProbe::OneExample do
    let(:copy) { Dir.mktmpdir("hecks-one-example") }
    let(:shell) { instance_double(Hecks::Adapters::Shell, capture: result) }
    let(:result) { instance_double(Hecks::Adapters::Shell::Result, ok?: true, out: "", err: "") }
    let(:red) { "impacted specs red: failing spec: ./spec/x_spec.rb:12 # X breaks, badly" }
    let(:runner) do
      described_class.new(whole: ->(_copy, _files) { raise failure, red }, shell: shell)
    end

    before do
      FileUtils.mkdir_p(File.join(copy, "spec"))
      File.write(File.join(copy, "spec/x_spec.rb"), "")
    end

    after { FileUtils.remove_entry(copy) }

    # A first run of the whole files, red, which names the failing example.
    def named
      runner.call(copy, ["spec/x_spec.rb"])
    rescue failure
      runner
    end

    it "runs the spec files whole until a red run names the failing example" do
      expect { runner.call(copy, ["spec/x_spec.rb"]) }.to raise_error(failure, /X breaks, badly/)
    end

    it "runs only the named example after that, by its description" do
      named.call(copy, ["spec/x_spec.rb"])
      expect(shell).to have_received(:capture).with("exe/hecks", "test_suite_run.run_spec_example!", "file.value=spec/x_spec.rb",
                                                    "example.value=X breaks, badly", "--wait", env: {}, chdir: copy)
    end

    it "is red when the launcher refuses the example's run" do
      allow(result).to receive(:ok?).and_return(false)
      expect { named.call(copy, ["spec/x_spec.rb"]) }.to raise_error(failure, /1\) X breaks, badly/)
    end

    it "runs nothing, and is green, in a copy that does not hold the example's file" do
      named.call(Dir.tmpdir, ["spec/x_spec.rb"])
      expect(shell).not_to have_received(:capture)
    end
  end
end
