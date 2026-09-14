require "spec_helper"

# EVERY BLUEBOOK IN THE REPO IS ACCOUNTED FOR — inside some Hecks::Corpus
# kind, or excluded with a stated reason. A domain living outside every
# kind is still swept by bin/fuzz, but invisible to every check that walks
# kinds (the model checker, parser parity, the corpus load gate); an
# exclusion that no longer matches anything is a reason nobody can check.
RSpec.describe Hecks::Corpus do
  # The domain directory a member stands for, spelled the way
  # `sweepable_domains` spells it: a `bluebook/` folder is its parent.
  def domain_dir_of(member)
    dir = File.directory?(member.path) ? member.path : File.dirname(member.path)
    File.basename(dir) == "bluebook" ? File.dirname(dir) : dir
  end

  it "covers every sweepable domain with some kind" do
    covered = described_class.members.map { |member| domain_dir_of(member) }.uniq
    uncovered = described_class.sweepable_domains - covered

    expect(uncovered).to be_empty,
                         "no Hecks::Corpus kind holds #{uncovered.join(', ')} — add a kind, or an EXCLUDED entry with its reason"
  end

  it "keeps every committed-source exclusion matching at least one bluebook" do
    bluebooks = Dir.chdir(described_class::ROOT) { Dir.glob("**/*.bluebook") }

    stale = (described_class::EXCLUDED.keys - described_class::RUNTIME_ONLY_EXCLUSIONS)
            .select { |pattern| bluebooks.grep(pattern).empty? }
    expect(stale).to be_empty, "#{stale.map(&:inspect).join(', ')} match nothing — delete them from Corpus::EXCLUDED"
  end

  it "names a reason for every exclusion" do
    expect(described_class::EXCLUDED.values).to all(match(/\S/))
  end

  it "keeps stems unique within each kind" do
    described_class.members.group_by(&:kind).each do |kind, members|
      duplicates = members.map(&:stem).tally.select { |_, count| count > 1 }.keys
      expect(duplicates).to be_empty, "#{kind}: #{duplicates.join(', ')} name more than one member"
    end
  end

  it "gives every directory-kind member a bluebook to load" do
    empty = described_class.members(*described_class::DIRECTORY_KINDS.keys)
                           .reject { |member| described_class.source_of(member) }
    expect(empty.map(&:path)).to be_empty
  end

  it "refuses a kind it does not know" do
    expect { described_class.members(:nonsense) }.to raise_error(ArgumentError, /unknown corpus kind :nonsense/)
  end
end
