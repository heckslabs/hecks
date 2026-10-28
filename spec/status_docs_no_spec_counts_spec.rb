require "spec_helper"

# The status documents make no claim about how many specs there are. A count is true on
# the day it is written and wrong after the next merge, so these files say "the whole
# suite" and leave the number to the runner.
RSpec.describe "status documents" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:count_claims) do
    [
      /\b\d[\d,]*\s+(?:rspec\s+)?(?:examples|specs|tests)\b/i,
      %r{\b(?:rspec|specs?|examples)\s+\d{2,}/\d{2,}\b}i,
      %r{\b\d{2,}/\d{2,}\s+(?:examples|specs|tests)\b}i
    ]
  end

  let(:thing_totals) do
    number = /(?:\d[\d,]*|(?:two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\b)/i
    nouns = %w[actions aggregates declarations commands contexts cops gates kinds properties adapters bluebooks].join("|")
    thing = /(?:generated\s+)?(?:#{nouns})/i
    /\b#{number.source}\s+#{thing.source}\b/i
  end

  %w[README.md CONTRIBUTING.md docs/1.0-readiness.md].each do |doc|
    it "#{doc} states no spec or example count" do
      claims = File.readlines(File.join(root, doc)).each_with_index.filter_map do |line, index|
        "#{doc}:#{index + 1}: #{line.strip}" if count_claims.any? { |pattern| line.match?(pattern) }
      end

      expect(claims).to be_empty,
                        "spec counts go stale — say 'the whole suite' instead:\n#{claims.join("\n")}"
    end

    it "#{doc} states no total of the things the language holds" do
      claims = File.readlines(File.join(root, doc)).each_with_index.filter_map do |line, index|
        "#{doc}:#{index + 1}: #{line.strip}" if line.match?(thing_totals)
      end

      expect(claims).to be_empty,
                        "totals go stale — say 'every', 'several' or 'these' instead:\n#{claims.join("\n")}"
    end
  end
end
