require "spec_helper"
require "json"

# WHICH REGEXES A BLUEBOOK MAY SAY, from Ruby's side.
#
# The Rust half is rust/src/bluebook/pattern_subset.rs, and both read the same
# fixture. A pattern one runtime admits and the other refuses is a bluebook that
# loads in one and not the other, which is the failure this exists to stop.
RSpec.describe Hecksagain::Bluebook::PatternSubset do
  # PATTERNS_CONTRACT, not CONTRACT : a constant assigned inside an RSpec.describe
  # block lands on Object, so a bare `CONTRACT` here silently overwrote the one in
  # naming_spec and broke a test in a file this one never mentions. Whichever
  # loaded second won, which made it look like load-order flakiness.
  PATTERNS_CONTRACT = File.join(InMemoryDomain::ROOT, "spec/parity/fixtures/patterns.json").freeze

  describe "the constructs it refuses" do
    # The first four cannot both be PARSED. The last two can — and mean different
    # things, which is the dangerous half : nothing errors, the two runtimes just
    # quietly disagree about whether a value is valid.
    {
      '(a)\1'          => "backreference",
      '(?<x>a)\k<x>'   => "named backreference",
      '^(?=.*[A-Z]).+$' => "lookahead",
      '(?<=a)b'        => "lookbehind",
      '(?>ab)'         => "atomic group",
      'a*+'            => "possessive quantifier",
      '^\d{4}$'        => "perl character class",
      '^\w+$'          => "perl character class",
      '^[^@\s]+$'      => "perl character class",
      '^[[:digit:]]$'  => "posix bracket class",
      '^[[:alpha:]]+$' => "posix bracket class"
    }.each do |pattern, construct|
      it "refuses #{pattern} as a #{construct}" do
        rejection = described_class.validate(pattern)

        expect(rejection).not_to be_nil, "#{pattern} should have been refused"
        expect(rejection.construct).to eq(construct)
      end
    end
  end

  describe "the shapes a domain actually needs" do
    [
      '^[A-Z]{3}-[0-9]{4}$',
      '^[0-9]{5}(-[0-9]{4})?$',
      '^\+?[0-9 ()-]{7,20}$',
      '^[^@ ]+@[^@ ]+\.[^@ ]+$',
      '^(red|green|blue)$',
      '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$',
      ''
    ].each do |pattern|
      it "admits #{pattern.inspect}" do
        expect(described_class.validate(pattern)).to be_nil
      end
    end

    # An ESCAPED construct is a literal, not a violation.
    it "reads an escaped construct as the characters it spells" do
      expect(described_class.validate('\(\?=')).to be_nil
      expect(described_class.validate('(?<year>[0-9]{4})')).to be_nil
      expect(described_class.validate('\0')).to be_nil
    end
  end

  # THE DIFFERENTIAL. The same file the Rust test reads : a recorded contract both
  # runtimes answer to, so a regression in EITHER is caught. Recording one
  # runtime's answers and diffing the other against them would have made the
  # first unilaterally right.
  describe "the recorded contract" do
    it "reads every admitted pattern the way the fixture says" do
      rows = JSON.parse(File.read(PATTERNS_CONTRACT))
      expect(rows).not_to be_empty

      disagreements = rows.reject do |row|
        Regexp.new(row.fetch("pattern")).match?(row.fetch("input")) == row.fetch("matches")
      end

      expect(disagreements).to be_empty,
                               "Ruby departs from the contract on: " \
                               "#{disagreements.map { |r| "#{r['pattern'].inspect} against #{r['input'].inspect}" }.join(', ')}"
    end

    it "only records patterns the subset admits" do
      refused = JSON.parse(File.read(PATTERNS_CONTRACT)).filter_map do |row|
        rejection = described_class.validate(row.fetch("pattern"))
        "#{row.fetch('pattern').inspect} (#{rejection.construct})" if rejection
      end

      expect(refused.uniq).to be_empty,
                              "the contract records patterns a bluebook may not say: #{refused.uniq.join(', ')}"
    end
  end
end
