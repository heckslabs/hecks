require "spec_helper"

# `matches: :name` stands for exactly the regex the language gives that name, in both parsers.
RSpec.describe Hecks::Bluebook::NamedPattern do
  let(:rust_table) do
    File.read(File.expand_path("../rust/parser/src/build/named_pattern.rs", __dir__))
        .scan(/\(\s*"(\w+)",\s*r"([^"]*)",?\s*\)/).to_h { |name, source| [name.to_sym, source] }
  end

  it "is the table the Rust parser holds, name for name and regex for regex" do
    expect(rust_table).to eq(described_class::TABLE)
  end

  it "names only patterns every engine reads the same way" do
    described_class::TABLE.each_value do |source|
      expect(Hecks::Bluebook::PatternSubset.validate(source)).to be_nil, source
    end
  end

  it "is put into words by the glossary, name for name" do
    words = Hecks::Projections::Glossary::Sentences::ValueObjects::PATTERN_WORDS
    expect(words.keys).to match_array(described_class::TABLE.keys)
  end

  it "refuses a name the language does not give, listing the ones it does" do
    expect { described_class.source(:zip_code) }
      .to raise_error(ArgumentError, /zip_code.*not a named pattern.*present/)
  end

  describe "an attribute declared with matches:" do
    def attribute_for(**options)
      builder = Class.new { include Hecks::Bluebook::DSL::AttributeCollector }.new
      builder.attribute_impl(:value, String, **options)
      builder.attributes.first
    end

    it "carries the regex the name stands for" do
      expect(attribute_for(matches: :snake_name).pattern).to eq("^[a-z][a-z0-9_]*$")
    end

    it "refuses matches: beside pattern:" do
      expect { attribute_for(matches: :present, pattern: "a") }
        .to raise_error(ArgumentError, /both state the pattern/)
    end
  end
end
