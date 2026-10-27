require "spec_helper"
require "json"
require "open3"
require "hecks/forms/html_pattern"

# An input's `pattern` is read by a browser as JavaScript in its `v` mode, so a pattern as Ruby
# wrote it is, when it uses a Ruby spelling or a bare `-` or `{` in a character class, a pattern the
# browser cannot compile and ignores.
RSpec.describe Hecks::Forms::HtmlPattern do
  # Spellings that differ between Ruby and a browser, each of which a bluebook declares somewhere.
  HTML_PATTERN_CASES = [
    "\\A[0-9]{4}\\z", "\\A[a-z][a-z0-9_]*\\z", "^[a-z0-9][a-z0-9_-]*$", "^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$",
    "^[a-z0-9_-]+\\.wasm$", "^(?:[^{}]|\\{(?:name|storage_name)\\})*$", "^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$",
    "^[A-Za-z0-9][A-Za-z0-9.-]*$", "^https?://", "^[-a-z]+$", "[^-a-z]", "\\h+", "[\\h-]+"
  ].freeze

  describe ".for" do
    it "writes Ruby's start and end of value as the ones JavaScript has", :aggregate_failures do
      expect(described_class.for("\\Aab\\z")).to eq(".*(?:^ab$).*")
      expect(described_class.for("\\Aab\\Z")).to eq(".*(?:^ab$).*")
    end

    it "escapes a literal hyphen that ends or starts a character class", :aggregate_failures do
      expect(described_class.for("[a-z0-9_-]+")).to eq(".*(?:[a-z0-9_\\-]+).*")
      expect(described_class.for("[-a-z]")).to eq(".*(?:[\\-a-z]).*")
    end

    it "keeps a hyphen that makes a range" do
      expect(described_class.for("[a-z]")).to eq(".*(?:[a-z]).*")
    end

    it "escapes the characters a character class refuses bare" do
      expect(described_class.for("[^{}|/()]")).to eq(".*(?:[^\\{\\}\\|\\/\\(\\)]).*")
    end

    it "leaves those characters alone outside a character class" do
      expect(described_class.for("(a|b){2}/")).to eq(".*(?:(a|b){2}/).*")
    end

    it "writes a hex digit as a range, inside a character class or out", :aggregate_failures do
      expect(described_class.for("\\h")).to eq(".*(?:[0-9a-fA-F]).*")
      expect(described_class.for("[\\h-]")).to eq(".*(?:[0-9a-fA-F\\-]).*")
    end

    it "leaves an escaped backslash before a letter as it is" do
      expect(described_class.for("a\\\\A")).to eq(".*(?:a\\\\A).*")
    end

    it "answers nil for an attribute with no pattern" do
      expect(described_class.for(nil)).to be_nil
    end
  end

  describe "in a JavaScript engine" do
    COMPILE_ALL = <<~JS.freeze
      const patterns = JSON.parse(require("fs").readFileSync(0, "utf8"));
      const invalid = patterns.filter((p) => { try { new RegExp(`^(?:${p})$`, "v"); return false; } catch (e) { return true; } });
      console.log(JSON.stringify(invalid));
    JS

    def node_major
      version, status = Open3.capture2("node", "--version")
      status.success? ? version[/\d+/].to_i : 0
    rescue Errno::ENOENT
      0
    end

    # The patterns a browser could not compile, of those given, as a JavaScript engine reports them.
    def uncompilable(patterns)
      out, = Open3.capture2("node", "-e", COMPILE_ALL, stdin_data: JSON.generate(patterns))
      JSON.parse(out)
    end

    before { skip "node 20 or later is not installed" if node_major < 20 }

    it "compiles every pattern the bluebooks declare in a form a browser reads" do
      patterns = HTML_PATTERN_CASES + Hecks::Bluebook::NamedPattern::TABLE.values

      expect(uncompilable(patterns.map { |pattern| described_class.for(pattern) })).to be_empty
    end

    it "finds the patterns that are not compilable as Ruby wrote them", :aggregate_failures do
      expect(uncompilable(["\\A[0-9]{4}\\z", "[a-z0-9_-]+", "[^{}]"]).size).to eq(3)
      expect(uncompilable(["^[0-9]+$"])).to be_empty
    end
  end
end
