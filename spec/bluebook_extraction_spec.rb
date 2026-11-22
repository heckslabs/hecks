require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "hecks/hecks/adapters/codebase/bluebook_extraction"

# The quick gate boots each bluebook a branch changed, so a rule the IR cannot carry is refused at
# submit and not at push.
RSpec.describe Hecks::Adapters::Codebase::BluebookExtraction do
  let(:root) { Dir.mktmpdir("bluebook-extraction") }
  let(:tree) { Hecks::Adapters::Codebase::Tree.new(root: root) }
  let(:good) do
    "Hecks.bluebook \"Fine\" do\n  aggregate(\"Thing\") do\n    attribute :name, Name\n    " \
      "identified_by :name\n    value_object(\"Name\", String)\n    command(\"Do\") { emits \"Done\" }\n  end\nend\n"
  end
  let(:bad) do
    "Hecks.bluebook \"Broken\" do\n  aggregate(\"Thing\") do\n    " \
      "command(\"Do\") { given(\"unreadable\", &eval(\"proc { 1 < 2 }\")) }\n  end\nend\n"
  end

  after { FileUtils.remove_entry(root) }

  define_method(:git) do |*args|
    Open3.capture2e("git", "-C", root, "-c", "user.name=t", "-c", "user.email=t@t", *args)
  end

  define_method(:write) do |path, text|
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), text)
  end

  before do
    git("init", "-q")
    write("lib/a/a.bluebook", good)
    git("add", ".")
    git("commit", "-q", "-m", "base")
  end

  describe "a changed bluebook holding a rule the IR cannot carry" do
    before { write("lib/a/a.bluebook", bad) }

    it "is refused, naming the file and the refusal" do
      expect { described_class.call(tree, base: "HEAD") }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, %r{lib/a/a\.bluebook.*did not survive extraction}m)
    end
  end

  describe "a changed bluebook whose rules all extract" do
    before { write("lib/a/a.bluebook", "#{good}\n") }

    it "passes, naming how many it read" do
      expect(described_class.call(tree, base: "HEAD")).to include("1 changed bluebook")
    end
  end

  describe "a branch that changed no bluebook" do
    it "passes having read none" do
      expect(described_class.call(tree, base: "HEAD")).to include("0 changed bluebook")
    end
  end
end
