# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_github"

# What the board keeps between reads stays bounded however long it serves: its kept answers are
# only those asked within their ttl, and its memo of train attempts only the attempts of the runs
# still in the flakes window.
RSpec.describe "the board's kept reads" do
  let(:unavailable) { Hecks::Adapters::PipelineBoard::Unavailable }

  describe Hecks::Adapters::PipelineBoard::Cache do
    let(:clock) { [0.0] }
    let(:cache) { described_class.new(ttl: 20, clock: -> { clock.first }) }

    def ask_many(count)
      count.times do |index|
        clock[0] = index.to_f
        cache.fetch([:log, index]) { "text #{index}" }
      end
    end

    def fail_once = cache.fetch(:gone) { raise unavailable, "502" }

    it "holds only the answers asked within the ttl, after thousands of distinct reads" do
      ask_many(5000)
      expect(cache.size).to be <= 21
    end

    it "forgets a failure on the same rule as an answer", :aggregate_failures do
      expect { fail_once }.to raise_error(unavailable)
      clock[0] = 21.0
      cache.fetch(:other) { clock.first }
      expect(cache.size).to eq(1)
    end
  end

  describe Hecks::Adapters::PipelineBoard::FlakeMemo do
    let(:memo) { described_class.new }

    it "answers a kept attempt without asking again" do
      asked = []
      2.times { memo.fetch([1, 1]) { asked << 1 } }
      expect(asked.size).to eq(1)
    end

    it "keeps nothing for an attempt whose read failed", :aggregate_failures do
      expect { memo.fetch([1, 1]) { raise unavailable, "502" } }.to raise_error(unavailable)
      expect(memo.size).to eq(0)
    end

    it "keeps only the attempts it is told are still wanted" do
      (1..3000).each { |id| memo.fetch([id, 1]) { [] } }
      memo.keep([[2999, 1], [3000, 1]])
      expect(memo.size).to eq(2)
    end
  end
end
