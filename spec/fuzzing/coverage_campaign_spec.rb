require "spec_helper"
require "hecks/fuzzing/sequence_generator"
require "hecks/fuzzing/coverage_campaign"

# `CoverageCampaign` over synthetic traces — what is pinned here is the
# campaign's own bookkeeping (what enters the corpus, what a plan says),
# never a generator run. `SequenceGenerator`'s side of the contract
# (a prefix really reproduces the steps it names) is pinned in
# sequence_generator_spec.rb.
RSpec.describe Hecks::Fuzzing::CoverageCampaign do
  def trace(tuples, verbs: %w[D::A.Open D::A.Close D::A.Rare])
    Hecks::Fuzzing::SequenceGenerator::Trace.new(
      steps: [], coverage: tuples.each_with_index.map { |tuple, index| [index, tuple] }, verbs: verbs
    )
  end

  def tuple(verb, outcome = "ok") = "#{verb} | verb | absent | - | #{outcome}"

  it "plans nothing at all while splicing and favor are both off" do
    campaign = described_class.new(splice_probability: 0.0, favor_count: 0)
    campaign.record(1, campaign.plan(1), trace([tuple("D::A.Open")]))

    plan = campaign.plan(2)
    expect(plan.prefix).to be_nil
    expect(plan.favor).to eq([])
    expect(plan.generator_options).to eq(prefix: nil, favor: [])
  end

  it "admits a seed that reached a new tuple, cut at its LAST new tuple" do
    campaign = described_class.new(splice_probability: 1.0, favor_count: 0)
    campaign.record(1, campaign.plan(1), trace([tuple("D::A.Open"), tuple("D::A.Close"), tuple("D::A.Open")]))

    expect(campaign.corpus).to eq([{ spec: { "seed" => 1, "favor" => [] }, attempts: 2 }])
  end

  it "does not admit a seed that reached nothing new" do
    campaign = described_class.new(splice_probability: 1.0, favor_count: 0)
    campaign.record(1, campaign.plan(1), trace([tuple("D::A.Open")]))
    campaign.record(2, campaign.plan(2), trace([tuple("D::A.Open"), tuple("D::A.Open")]))

    expect(campaign.corpus.map { |entry| entry[:spec]["seed"] }).to eq([1])
  end

  it "counts a different outcome for the same verb as new coverage" do
    campaign = described_class.new(splice_probability: 0.0, favor_count: 0)
    campaign.record(1, campaign.plan(1), trace([tuple("D::A.Open")]))
    campaign.record(2, campaign.plan(2), trace([tuple("D::A.Open", "TypeMismatch")]))

    expect(campaign.tuples_seen).to eq(2)
  end

  it "splices from the corpus, naming the whole prefix chain a seed needs to reproduce" do
    campaign = described_class.new(splice_probability: 1.0, favor_count: 0)
    campaign.record(1, campaign.plan(1), trace([tuple("D::A.Open"), tuple("D::A.Close")]))

    second = campaign.plan(2)
    expect(second.prefix).to include("seed" => 1, "favor" => [])
    expect(second.prefix["steps"]).to be_between(1, 2)

    campaign.record(2, second, trace([tuple("D::A.Rare")]))
    expect(campaign.corpus.last[:spec]).to include("seed" => 2, "prefix" => second.prefix)
  end

  it "plans the same thing for the same seed from the same record" do
    build = lambda do
      described_class.new(splice_probability: 0.5, favor_count: 2).tap do |campaign|
        (1..5).each { |seed| campaign.record(seed, campaign.plan(seed), trace([tuple("D::A.V#{seed}")])) }
      end
    end

    first  = build.call.plan(6)
    second = build.call.plan(6)
    expect(second).to eq(first)
  end

  it "favors never-hit declared verbs first, then the least hit, ties broken by name" do
    campaign = described_class.new(splice_probability: 0.0, favor_count: 2)
    campaign.record(1, campaign.plan(1),
                    trace([tuple("D::A.Open"), tuple("D::A.Open", "NotFound"), tuple("D::A.Close")]))

    expect(campaign.plan(2).favor).to eq(%w[D::A.Rare D::A.Close])
  end

  it "stops nesting prefixes past the depth limit" do
    campaign = described_class.new(splice_probability: 1.0, favor_count: 0, max_prefix_depth: 1)
    campaign.record(1, campaign.plan(1), trace([tuple("D::A.Open")]))
    spliced = campaign.plan(2)
    campaign.record(2, spliced, trace([tuple("D::A.Close")]))

    expect(campaign.corpus.size).to eq(1)
  end

  it "summarizes what the sweep reached in one line" do
    campaign = described_class.new(splice_probability: 0.0, favor_count: 0)
    campaign.record(1, campaign.plan(1), trace([tuple("D::A.Open")]))

    expect(campaign.summary).to start_with("coverage: 1 distinct").and include("1 seed(s) reached something new")
  end
end
