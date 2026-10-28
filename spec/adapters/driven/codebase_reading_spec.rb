require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/codebase/source_tree"

RSpec.describe Hecks::Adapters::Codebase::Reading do
  let(:root) { Dir.mktmpdir("hecks-reading") }
  let(:tree) { Hecks::Adapters::Codebase::Tree.new(root: root) }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  after do
    Hecks::Adapters::Codebase::Declarations.kept.delete(tree.root)
    FileUtils.remove_entry(root)
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.binwrite(File.join(root, path), text)
  end

  READING_BLUEBOOK = <<~TEXT.freeze
    Hecks.bluebook "Shop" do
      aggregate "Order" do
        command "Place" do
          goal "Take an order"
        end

        query "Open" do
          returns Document
        end
      end
    end
  TEXT

  describe ".read" do
    it "numbers each line" do
      write("a.txt", "one\ntwo\nthree\n")

      expect(described_class.read({ path: "a.txt", from: 2, to: 3 }, tree)).to eq("2: two\n3: three")
    end

    it "says where to go on when top cuts it short" do
      write("a.txt", "one\ntwo\nthree\n")

      expect(described_class.read({ path: "a.txt", top: 2 }, tree)).to eq("1: one\n2: two\n(1 more lines to 3; ask from=3)")
    end

    it "refuses a path that leaves the checkout" do
      expect { described_class.read({ path: "../outside" }, tree) }.to raise_error(failure, /outside the checkout/)
    end

    it "refuses a file that is not there" do
      expect { described_class.read({ path: "none.txt" }, tree) }.to raise_error(failure, /no such file/)
    end

    it "refuses a binary file" do
      write("a.bin", "a\0b")

      expect { described_class.read({ path: "a.bin" }, tree) }.to raise_error(failure, /not a text file/)
    end
  end

  describe ".outline" do
    it "lists each construct of a bluebook with its extent, indented by nesting" do
      write("shop.bluebook", READING_BLUEBOOK)

      expect(described_class.outline({ path: "shop.bluebook" }, tree).lines.map(&:chomp)).to eq(
        ['2-10: aggregate "Order"', '  3-5: command "Place"', '  7-9: query "Open"']
      )
    end

    it "lists the definitions of a Ruby file and ends a one-line method on its own line" do
      write("a.rb", "class A\n  def b = 1\n  def c\n    2\n  end\nend\n")

      expect(described_class.outline({ path: "a.rb" }, tree).lines.map(&:chomp)).to eq(
        ["1-6: class A", "  2-2: def b", "  3-5: def c"]
      )
    end

    it "lists the headings of a Markdown file, each ending where the next of its level begins" do
      write("a.md", "# One\ntext\n## Two\ntext\n# Three\n")

      expect(described_class.outline({ path: "a.md" }, tree).lines.map(&:chomp)).to eq(
        ["1-4: # One", "  3-4: ## Two", "5-5: # Three"]
      )
    end
  end

  describe ".declaration" do
    before { write("shop/shop.bluebook", READING_BLUEBOOK) }

    it "names the range where a construct is declared" do
      expect(described_class.declaration({ name: "Place" }, tree)).to eq('shop/shop.bluebook:3-5: command "Place"')
    end

    it "shows the block's text on request" do
      expect(described_class.declaration({ name: "Open", show: true }, tree))
        .to eq(%(shop/shop.bluebook:7-9: query "Open"\n7:     query "Open" do\n8:       returns Document\n9:     end))
    end

    it "keeps only the kind asked for" do
      write("shop/other.bluebook", %(aggregate "Place" do\nend\n))

      answer = described_class.declaration({ name: "Place", kind: "aggregate" }, tree)

      expect(answer).to eq('shop/other.bluebook:1-2: aggregate "Place"')
    end

    it "keeps only the paths asked for" do
      write("other/other.bluebook", %(command "Place" do\nend\n))

      answer = described_class.declaration({ name: "Place", paths: "other" }, tree)

      expect(answer).to eq('other/other.bluebook:1-2: command "Place"')
    end

    it "sees a file that changed after the scan" do
      described_class.declaration({ name: "Place" }, tree)
      write("shop/shop.bluebook", "\n#{READING_BLUEBOOK}")

      expect(described_class.declaration({ name: "Place" }, tree)).to eq('shop/shop.bluebook:4-6: command "Place"')
    end

    it "refuses a name nothing declares" do
      expect { described_class.declaration({ name: "Nothing" }, tree) }.to raise_error(failure, /nothing is declared/)
    end
  end
end
