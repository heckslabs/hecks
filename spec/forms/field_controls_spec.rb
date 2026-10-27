require "spec_helper"
require "hecks/forms/field_renderer"

# A browser holds an input's `pattern` to the whole value, and reads it as JavaScript; the domain
# finds its pattern anywhere in the value, as Ruby. The input carries the pattern translated, so
# the browser accepts exactly what the domain does.
RSpec.describe Hecks::Forms::FieldRenderer::Controls do
  describe ".html_pattern" do
    # Each pattern a bluebook declares in one of its forms, with values on both sides of it.
    CASES = {
      "[^ \\t\\n\\r]"                              => ["Margherita", "a b", "", "   "],
      "^https?://"                                 => ["https://example.com", "http://x", "ftp://x", ""],
      "^[0-9]+[.][0-9]+[.][0-9]+"                  => ["1.2.3", "1.2.3-beta", "v1.2.3", "1.2"],
      "\\A[0-9]{4}\\z"                             => ["2026", "20266", "abcd", ""],
      "\\A[a-z][a-z0-9_]*\\z"                      => ["ok_1", "1bad", "Upper", "a"],
      "^[0-9a-f]{7,40}$|^[0-9]+[.][0-9]+[.][0-9]+" => ["abc1234", "1.2.3", "zzz", "abc"],
      "^/"                                         => ["/path", "path", "/"],
      "\\h+"                                       => ["ff09", "xyz", ""],
      "a\\\\A"                                     => ["a\\A", "aA", "a"],
      "^[a-z0-9][a-z0-9_-]*$"                      => ["ok-1", "Bad", "a_b-", "-a", ""],
      "^(?:[^{}]|\\{(?:name|storage_name)\\})*$"   => ["abc", "a{b", "{name}", "{other}"]
    }.freeze

    # Whether a browser would accept `value`: it matches `^(?:pattern)$` over the whole value.
    def browser_accepts?(pattern, value)
      Regexp.new("\\A(?:#{described_class.html_pattern(pattern)})\\z").match?(value)
    end

    # Whether the domain would: Ruby finds the declared pattern anywhere in the value.
    def domain_accepts?(pattern, value) = Regexp.new(pattern).match?(value)

    def browser_verdicts(pattern, values) = values.map { |value| browser_accepts?(pattern, value) }

    def domain_verdicts(pattern, values) = values.map { |value| domain_accepts?(pattern, value) }

    CASES.each do |pattern, values|
      it "accepts what the domain accepts for #{pattern.inspect}" do
        expect(browser_verdicts(pattern, values)).to eq(domain_verdicts(pattern, values))
      end
    end

    it "wraps a pattern the domain finds anywhere in the value" do
      expect(described_class.html_pattern("[^ \\t\\n\\r]")).to eq(".*(?:[^ \\t\\n\\r]).*")
    end

    it "writes Ruby's start and end of value as the ones JavaScript has", :aggregate_failures do
      expect(described_class.html_pattern("\\Aab\\z")).to eq(".*(?:^ab$).*")
      expect(described_class.html_pattern("\\Aab\\Z")).to eq(".*(?:^ab$).*")
    end

    it "leaves an escaped backslash before a letter as it is" do
      expect(described_class.html_pattern("a\\\\A")).to eq(".*(?:a\\\\A).*")
    end

    it "carries no pattern for an attribute with none" do
      expect(described_class.html_pattern(nil)).to be_nil
    end
  end
end
