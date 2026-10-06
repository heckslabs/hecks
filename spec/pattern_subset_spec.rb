require "spec_helper"
require "json"

# Which regexes a bluebook may say: a `pattern:` stays inside what regex engines agree on,
# so a pattern never loads in one place and not another.
RSpec.describe Hecks::Bluebook::PatternSubset do
  # Named PATTERNS_CONTRACT: a constant assigned in an RSpec.describe lands on Object, and a
  # bare `CONTRACT` overwrote the one in naming_spec.
  PATTERNS_CONTRACT = File.join(InMemoryDomain::ROOT, "spec/corpus/fixtures/patterns.json").freeze

  describe "the constructs it refuses" do
    # The first four need a backtracking engine. The last two every engine parses but reads
    # differently, so nothing errors and engines quietly disagree.
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
      it "refuses #{pattern} as a #{construct}", :aggregate_failures do
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

    # An escaped construct is a literal, not a violation.
    it "reads an escaped construct as the characters it spells", :aggregate_failures do
      expect(described_class.validate('\(\?=')).to be_nil
      expect(described_class.validate("(?<year>[0-9]{4})")).to be_nil
      expect(described_class.validate('\0')).to be_nil
    end
  end

  describe "character-class interiors" do
    # A `*` or `+` inside `[...]` is a literal character, not a quantifier —
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

    # A genuine possessive quantifier, including bounded `{n}+`, is refused outside a class.
    {
      "a{2}+"    => "possessive quantifier",
      "a{2,4}+"  => "possessive quantifier",
      "a{2,}+"   => "possessive quantifier",
      "[ab]{2}+" => "possessive quantifier"
    }.each do |pattern, construct|
      it "refuses #{pattern} as a #{construct}", :aggregate_failures do
        rejection = described_class.validate(pattern)

        expect(rejection).not_to be_nil, "#{pattern} should have been refused"
        expect(rejection.construct).to eq(construct)
      end
    end
  end

  # Verdicts come from the fixture, not from the walk, so a regression is caught against
  # what was agreed.
  describe "the recorded contract" do
    def contract_rows = JSON.parse(File.read(PATTERNS_CONTRACT))

    # The rows whose pattern Ruby reads differently from what the fixture says.
    def disagreements(rows)
      rows.reject { |row| Regexp.new(row.fetch("pattern")).match?(row.fetch("input")) == row.fetch("matches") }
    end

    # The recorded patterns the subset refuses, each with the construct it names.
    def refused_patterns
      contract_rows.filter_map do |row|
        rejection = described_class.validate(row.fetch("pattern"))
        "#{row.fetch("pattern").inspect} (#{rejection.construct})" if rejection
      end.uniq
    end

    it "reads every admitted pattern the way the fixture says", :aggregate_failures do
      expect(contract_rows).not_to be_empty

      departures = disagreements(contract_rows).map { |r| "#{r["pattern"].inspect} against #{r["input"].inspect}" }
      expect(departures).to be_empty, "Ruby departs from the contract on: #{departures.join(", ")}"
    end

    it "only records patterns the subset admits" do
      expect(refused_patterns).to be_empty, "the contract records patterns a bluebook may not say: #{refused_patterns.join(", ")}"
    end
  end
end
