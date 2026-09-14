require "spec_helper"

# EVERY BLUEBOOK IN THE REPO LANDS IN A CHECK — a partition, not a filter.
# Each one is either inside some Hecks::Corpus kind (and so walked by the
# model checker, parser parity, the sweep, ...) or sent by a ROUTE to the
# check that owns it instead. A route is not a reason to look away: its
# destination has to exist and actually name what it receives, and a
# route with no destination yet is a gap this spec keeps visible.
RSpec.describe Hecks::Corpus do
  ROUTE_CHECKS = %i[named_in gitignored gap].freeze

  def self.committed
    @committed ||= IO.popen(%w[git ls-files], chdir: Hecks::Corpus::ROOT, &:read).split("\n").freeze
  end

  def committed = self.class.committed

  def root = described_class::ROOT

  # The committed bluebooks whose FIRST matching route is this one.
  def routed_to(route)
    committed.grep(/\.bluebook\z/).select { |path| described_class.route_for(path).equal?(route) }
  end

  def ignore_rules
    committed.grep(%r{(\A|/)\.gitignore\z}).flat_map { |file| File.readlines(File.join(root, file), chomp: true) }
  end

  def named_by_some_spec?(name)
    Dir.glob(File.join(root, "spec/**/*_spec.rb")).any? { |spec| File.read(spec).include?(name) }
  end

  it "covers every sweepable domain with some kind" do
    covered = described_class.members.map { |member| described_class.domain_dir_of(member) }.uniq
    uncovered = described_class.sweepable_domains - covered

    expect(uncovered).to be_empty,
                         "no Hecks::Corpus kind holds #{uncovered.join(', ')} — add a kind, or a ROUTE to the check that owns it"
  end

  it "gives every route a known check and a reason" do
    expect(described_class::ROUTES.map(&:check)).to all(satisfy { |check| ROUTE_CHECKS.include?(check) })
    expect(described_class::ROUTES.map(&:why)).to all(match(/\S/))
  end

  described_class::ROUTES.select { |route| route.check == :gitignored }.each do |route|
    it "keeps #{route.pattern.inspect} ignored, with nothing it matches committed" do
      expect(ignore_rules).to include(route.names)
      expect(committed.grep(route.pattern)).to be_empty
    end
  end

  described_class::ROUTES.select { |route| route.check == :named_in }.each do |route|
    it "routes #{route.pattern.inspect} to #{route.destination}, which names what it receives" do
      routed = routed_to(route)
      expect(routed).not_to be_empty, "matches no committed bluebook first — delete it from Corpus::ROUTES"

      text = File.read(File.join(root, route.destination))
      expected = route.names == :each_file ? routed.map { |path| File.basename(path, ".bluebook") } : [route.names]
      expect(expected.reject { |name| text.include?(name) }).to be_empty
    end
  end

  described_class::ROUTES.select { |route| route.check == :gap }.each do |route|
    it "still has no destination for #{route.pattern.inspect}" do
      pending route.why
      names = routed_to(route).map { |path| File.basename(path, ".bluebook") }
      expect(names).to all(satisfy { |name| named_by_some_spec?(name) })
    end
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
