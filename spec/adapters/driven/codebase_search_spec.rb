require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/codebase/source_tree"

RSpec.describe Hecks::Adapters::Codebase::Search do
  let(:root) { Dir.mktmpdir("hecks-search") }
  let(:tree) { Hecks::Adapters::Codebase::Tree.new(root: root) }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  after { FileUtils.remove_entry(root) }

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.binwrite(File.join(root, path), text)
  end

  def search(pattern, **args) = described_class.report({ pattern: pattern }.merge(args), tree)

  describe "what it answers" do
    it "names each matching line by path and line number" do
      write("lib/a.rb", "one\nPostgresEra here\nthree\n")

      expect(search("Era")).to eq("lib/a.rb:2: PostgresEra here")
    end

    it "lists files in path order" do
      write("b.txt", "hit\n")
      write("a.txt", "hit\n")

      expect(search("hit").lines.map { |row| row.split(":").first }).to eq(%w[a.txt b.txt])
    end

    it "searches only the paths named" do
      write("lib/a.rb", "hit\n")
      write("docs/b.md", "hit\n")

      expect(search("hit", paths: "docs")).to eq("docs/b.md:1: hit")
    end

    it "keeps only the first top rows" do
      write("a.txt", "hit\nhit\nhit\n")

      expect(search("hit", top: 2).lines.length).to eq(2)
    end
  end

  describe "what it leaves out" do
    it "skips directories that hold no source of their own", :aggregate_failures do
      %w[.git target node_modules tmp vendor].each { |dir| write("#{dir}/x.txt", "hit\n") }
      write("kept.txt", "hit\n")

      expect(search("hit")).to eq("kept.txt:1: hit")
    end

    it "skips a file with a NUL in its first block" do
      write("blob.bin", "hit\0hit\n")

      expect(search("hit")).to eq("")
    end

    it "skips a line that is not valid text" do
      write("a.txt", "hit \xff\nhit\n")

      expect(search("hit")).to eq("a.txt:2: hit")
    end
  end

  describe "what it refuses" do
    it "refuses a pattern that is not a regular expression" do
      expect { search("(") }.to raise_error(failure, /not a regular expression/)
    end
  end
end
