require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/doc_staleness"

# The check reads docs and comments for citations that point at nothing. The tree here
# is a small one: a few real files, and text that cites them or something gone.
RSpec.describe Hecks::DocStaleness do
  let(:root) { Dir.mktmpdir("doc-staleness") }

  before { write("lib/hecks/real.rb", "module Hecks\n  module Real\n    LIMIT = 3\n  end\nend\n") }

  after { FileUtils.remove_entry(root) }

  define_method(:write) do |path, text|
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), text)
  end

  define_method(:found) { described_class.findings(root: root).map(&:to_s) }

  describe "a backticked path in a doc" do
    it "is reported as file:line with the reason when it names nothing" do
      write("docs/a.md", "one\nsee `lib/hecks/gone.rb` here\n")
      expect(found).to eq(["docs/a.md:2: [doc-path] `lib/hecks/gone.rb` does not exist"])
    end

    it "passes when the file is there, with a line number after it" do
      write("docs/a.md", "see `lib/hecks/real.rb:3` and `lib/hecks/`\n")
      expect(found).to be_empty
    end

    it "is left alone in a fenced block" do
      write("docs/a.md", "```\nlib/hecks/gone.rb\n```\n")
      expect(found).to be_empty
    end

    it "is left alone when it is a glob, a placeholder or has an angle bracket" do
      write("docs/a.md", "`lib/x/thing.rb` `lib/hecks/*.rb` `spec/<name>_spec.rb`\n")
      expect(found).to be_empty
    end

    it "is left alone on a line marked staleness-check: skip" do
      write("docs/a.md", "<!-- staleness-check: skip -->\n`lib/hecks/gone.rb`\n")
      expect(found).to be_empty
    end
  end

  describe "a doc that records a past state" do
    it "is left alone under a Historical blockquote" do
      write("docs/a.md", "# T\n\n> Historical: kept as written.\n\n`lib/hecks/gone.rb`\n")
      expect(found).to be_empty
    end

    it "is left alone under a Status: Superseded line" do
      write("docs/a.md", "# T\n\nStatus: Superseded by 12\n\n`lib/hecks/gone.rb`\n")
      expect(found).to be_empty
    end
  end

  describe "a comment in Ruby" do
    it "reports a path it cites that is gone" do
      write("lib/hecks/a.rb", "# Reads spec/gone_spec.rb.\nclass A; end\n")
      expect(found.first).to start_with("lib/hecks/a.rb:1: [comment-path]")
    end

    it "does not read a string" do
      write("lib/hecks/a.rb", "PATH = \"lib/hecks/gone.rb\"\n")
      expect(found).to be_empty
    end

    it "reports a Hecks constant lib/ does not define" do
      write("lib/hecks/a.rb", "# Built by Hecks::Missing::Thing2.\nclass A; end\n")
      expect(found.first).to end_with("Hecks::Missing::Thing2 is not defined in lib/")
    end

    it "passes a Hecks constant lib/ defines" do
      write("lib/hecks/a.rb", "# Capped by Hecks::Real::LIMIT.\nclass A; end\n")
      expect(found).to be_empty
    end
  end

  describe "a comment in Rust" do
    it "reports a path it cites that is gone" do
      write("rust/a.rs", "let x = 1; // see docs/gone.md\n")
      expect(found).to eq(["rust/a.rs:1: [comment-path] `docs/gone.md` does not exist"])
    end

    it "does not read a string that holds slashes" do
      write("rust/a.rs", "let url = \"http://lib/hecks/gone.rb\";\n")
      expect(found).to be_empty
    end
  end

  describe "a YARD @param tag" do
    define_method(:def_with) { |tag, params| write("lib/hecks/a.rb", "# #{tag}\ndef run(#{params}) = 1\n") }

    it "is reported when the method takes no such parameter" do
      def_with("@param other [String] gone", "name")
      expect(found).to eq(["lib/hecks/a.rb:1: [yard-param] @param other is not a parameter of the method below"])
    end

    it "passes when the name is a parameter, in either tag order" do
      def_with("@param [String] name the one", "name, *rest")
      expect(found).to be_empty
    end

    it "passes a hash-key doc under a named **opts" do
      def_with("@param color [String] a key of opts", "name, **opts")
      expect(found).to be_empty
    end

    it "passes under an anonymous splat" do
      def_with("@param anything [String] forwarded", "*")
      expect(found).to be_empty
    end
  end

  describe ".check" do
    it "raises with every finding" do
      write("docs/a.md", "`lib/hecks/gone.rb`\n")
      expect { described_class.check(root: root) }.to raise_error(described_class::Failure, /gone\.rb/)
    end

    it "reads only the paths it is given" do
      write("docs/a.md", "`lib/hecks/gone.rb`\n")
      expect(described_class.check(root: root, paths: ["lib"])).to eq(described_class::CLEAN)
    end
  end
end
