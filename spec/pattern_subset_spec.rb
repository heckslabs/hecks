require "spec_helper"
require "json"

# WHICH REGEXES A BLUEBOOK MAY SAY.
#
# A `pattern:` is declared data, so it stays inside what regex engines agree
# on. A pattern one engine admits and another refuses is a bluebook that
# loads in one place and not another, which is the failure this exists to stop.
RSpec.describe Hecks::Bluebook::PatternSubset do
  # PATTERNS_CONTRACT, not CONTRACT : a constant assigned inside an RSpec.describe
  # block lands on Object, so a bare `CONTRACT` here silently overwrote the one in
  # naming_spec and broke a test in a file this one never mentions. Whichever
  # loaded second won, which made it look like load-order flakiness.
  PATTERNS_CONTRACT = File.join(InMemoryDomain::ROOT, "spec/corpus/fixtures/patterns.json").freeze

  describe "the constructs it refuses" do
    # The first four only a backtracking engine can PARSE. The last two every
    # engine parses — and means differently, which is the dangerous half :
    # nothing errors, engines just quietly disagree about whether a value is
    # valid.
    {
      '(a)\1'           => "backreference",
      '(?<x>a)\k<x>'    => "named backreference",
      "^(?=.*[A-Z]).+$" => "lookahead",
      "(?<=a)b"         => "lookbehind",
      "(?>ab)"          => "atomic group",
      "a*+"             => "possessive quantifier",
      '^\d{4}$'         => "perl character class",
      '^\w+$'           => "perl character class",
      '^[^@\s]+$'       => "perl character class",
      "^[[:digit:]]$"   => "posix bracket class",
      "^[[:alpha:]]+$"  => "posix bracket class"
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
      "^[A-Z]{3}-[0-9]{4}$",
      "^[0-9]{5}(-[0-9]{4})?$",
      '^\+?[0-9 ()-]{7,20}$',
      '^[^@ ]+@[^@ ]+\.[^@ ]+$',
      "^(red|green|blue)$",
      "^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$",
      ""
    ].each do |pattern|
      it "admits #{pattern.inspect}" do
        expect(described_class.validate(pattern)).to be_nil
      end
    end

    # An ESCAPED construct is a literal, not a violation.
    it "reads an escaped construct as the characters it spells" do
      expect(described_class.validate('\(\?=')).to be_nil
      expect(described_class.validate("(?<year>[0-9]{4})")).to be_nil
      expect(described_class.validate('\0')).to be_nil
    end
  end

  describe "character-class interiors" do
    # A `*` or `+` INSIDE `[...]` is a literal character, not a quantifier —
    # the walk must not mistake it for a possessive-quantifier attempt.
    [
      "[*+]",
      "[+*]",
      "[?+]",
      "[a*+]",
      "^[*+?]+$",
      "[]]",
      "[^]]",
      "[]*+]"
    ].each do |pattern|
      it "admits #{pattern.inspect} (literal quantifier characters in a class)" do
        expect(described_class.validate(pattern)).to be_nil
      end
    end

    # A genuine possessive quantifier — including the bounded `{n}+` form,
    # which the old scan never even looked for — is still refused when it
    # occurs OUTSIDE any character class.
    {
      "a{2}+"    => "possessive quantifier",
      "a{2,4}+"  => "possessive quantifier",
      "a{2,}+"   => "possessive quantifier",
      "[ab]{2}+" => "possessive quantifier"
    }.each do |pattern, construct|
      it "refuses #{pattern} as a #{construct}" do
        rejection = described_class.validate(pattern)

        expect(rejection).not_to be_nil, "#{pattern} should have been refused"
        expect(rejection.construct).to eq(construct)
      end
    end
  end

  # A RECORDED CONTRACT, not a re-derived one : the fixture holds the
  # expected verdicts, so a regression in the walk is caught against what was
  # agreed rather than against whatever the walk now says. Recording the
  # implementation's own answers and diffing it against itself would have
  # made it unilaterally right.
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
