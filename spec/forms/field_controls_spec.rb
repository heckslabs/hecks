require "spec_helper"
require "hecks/forms/field_renderer"

# A browser holds an input's `pattern` to the whole value, the domain finds its pattern anywhere in
# it, so the input has to carry the pattern wrapped or it accepts a single character.
RSpec.describe Hecks::Forms::FieldRenderer::Controls do
  describe ".html_pattern" do
    it "wraps a pattern the domain finds anywhere in the value" do
      expect(described_class.html_pattern("[^ \\t\\n\\r]")).to eq(".*(?:[^ \\t\\n\\r]).*")
    end

    it "wraps a pattern so that a whole word, not one character, satisfies it" do
      expect(Regexp.new("\\A#{described_class.html_pattern("[^ \\t\\n\\r]")}\\z")).to match("Margherita")
    end

    it "leaves a pattern that anchors itself alone", :aggregate_failures do
      expect(described_class.html_pattern("^[a-z]+$")).to eq("^[a-z]+$")
      expect(described_class.html_pattern("\\A[a-z]+\\z")).to eq("\\A[a-z]+\\z")
    end

    it "carries no pattern for an attribute with none" do
      expect(described_class.html_pattern(nil)).to be_nil
    end
  end
end
