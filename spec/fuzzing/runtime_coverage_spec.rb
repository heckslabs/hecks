require "spec_helper"
require "tmpdir"
require "hecks/fuzzing/runtime_coverage"
require "hecks/fuzzing/sequence_generator"
require "hecks/fuzzing/coverage_campaign"

RSpec.describe Hecks::Fuzzing::RuntimeCoverage, :aggregate_failures do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = File.realpath(dir)
      File.write(File.join(@dir, "branchy.rb"), <<~RUBY)
        def branchy(flag)
          if flag
            :yes
          else
            :no
          end
        end
      RUBY
      load File.join(@dir, "branchy.rb")
      example.run
    end
  end

  it "answers the block's value and the lines it reached inside the roots" do
    value, reached = described_class.measure(roots: [@dir]) { branchy(true) }

    expect(value).to eq(:yes)
    expect(reached).to include("#{@dir}/branchy.rb:3")
    expect(reached).not_to include("#{@dir}/branchy.rb:5")
  end

  it "ignores code outside the roots" do
    _, reached = described_class.measure(roots: [@dir]) { [1, 2].sum }

    expect(reached).to be_empty
  end

  it "is reproducible: the same block reaches the same keys" do
    first  = described_class.measure(roots: [@dir]) { branchy(false) }.last
    second = described_class.measure(roots: [@dir]) { branchy(false) }.last

    expect(first).to eq(second)
  end

  it "needs a block" do
    expect { described_class.measure }.to raise_error(ArgumentError, /needs a block/)
  end

  describe "feeding a CoverageCampaign" do
    def trace(tuples)
      Hecks::Fuzzing::SequenceGenerator::Trace.new(
        steps: [{ "verb" => "D::A.Open" }], verbs: ["D::A.Open"],
        coverage: tuples.each_with_index.map { |tuple, index| [index, tuple] }
      )
    end

    let(:tuple) { "D::A.Open | verb | absent | - | ok" }

    it "admits a seed that reached only new runtime lines, whole" do
      campaign = Hecks::Fuzzing::CoverageCampaign.new(splice_probability: 1.0, favor_count: 0)
      campaign.record(1, campaign.plan(1), trace([tuple]), runtime: Set["a.rb:1"])
      campaign.record(2, campaign.plan(2), trace([tuple]), runtime: Set["a.rb:1", "a.rb:2"])
      campaign.record(3, campaign.plan(3), trace([tuple]), runtime: Set["a.rb:2"])

      expect(campaign.corpus.map { |entry| entry[:spec]["seed"] }).to eq([1, 2])
      expect(campaign.corpus.last[:attempts]).to eq(1)
      expect(campaign.runtime_seen).to eq(2)
      expect(campaign.summary).to include("2 runtime line/branch key(s)")
    end

    it "leaves admission to tuples alone when no runtime keys are given" do
      campaign = Hecks::Fuzzing::CoverageCampaign.new(splice_probability: 1.0, favor_count: 0)
      campaign.record(1, campaign.plan(1), trace([tuple]))
      campaign.record(2, campaign.plan(2), trace([tuple]))

      expect(campaign.corpus.size).to eq(1)
      expect(campaign.runtime_seen).to eq(0)
      expect(campaign.summary).not_to include("runtime")
    end

    it "survives a save and load, so a later tick does not rediscover the same lines" do
      campaign = Hecks::Fuzzing::CoverageCampaign.new(splice_probability: 1.0, favor_count: 0)
      campaign.record(1, campaign.plan(1), trace([tuple]), runtime: Set["a.rb:1"])

      state = JSON.parse(JSON.generate(campaign.to_h))
      resumed = Hecks::Fuzzing::CoverageCampaign.load(state, splice_probability: 1.0, favor_count: 0)
      resumed.record(2, resumed.plan(2), trace([tuple]), runtime: Set["a.rb:1"])

      expect(resumed.runtime_seen).to eq(1)
      expect(resumed.corpus.map { |entry| entry[:spec]["seed"] }).to eq([1])
    end
  end
end
