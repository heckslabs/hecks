require "spec_helper"
require_relative "../../support/fake_codebase_shell"
require "hecks/hecks/adapters/codebase/source_tree"

RSpec.describe Hecks::Adapters::Codebase::Inspection do
  let(:tree) { Hecks::Adapters::Codebase::Tree.new }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  def inspect_with(operation, held, shell) = described_class.call(operation, held, tree, shell: shell)

  def word(value) = { value: value }

  describe "what it starts" do
    it "runs the tool through bundle exec, from the checkout's root, over the files named", :aggregate_failures do
      shell = FakeCodebaseShell.new(["ranked", 0])

      expect(inspect_with("flog", { paths: word("lib/hecks/canonical_json.rb") }, shell)).to eq("ranked")
      expect(shell.asked.first[:command]).to eq(%w[exec flog --methods-only lib/hecks/canonical_json.rb])
      expect(shell.asked.first[:chdir]).to eq(tree.root)
    end

    it "leaves out the files the style config excludes" do
      shell = FakeCodebaseShell.new

      inspect_with("flay", { paths: word("lib/hecks") }, shell)

      expect(shell.command).not_to include("lib/hecks/vocabulary.rb")
    end

    it "keeps only the first top lines of the report" do
      shell = FakeCodebaseShell.new(["a\nb\nc\n", 0])

      expect(inspect_with("flog", { paths: word("lib/hecks/canonical_json.rb"), top: word(2) }, shell)).to eq("a\nb\n")
    end
  end

  describe "how it ends" do
    it "takes reek's status 2 as a report of smells" do
      shell = FakeCodebaseShell.new(["smells", 2])

      expect(inspect_with("reek", { paths: word("lib/hecks/canonical_json.rb") }, shell)).to eq("smells")
    end

    it "refuses when a tool ends in a status that is not a report" do
      shell = FakeCodebaseShell.new(["", 1])

      expect { inspect_with("flog", { paths: word("lib/hecks/canonical_json.rb") }, shell) }
        .to raise_error(failure, /flog ended with status 1/)
    end

    it "refuses when the paths name no Ruby file" do
      expect { inspect_with("flog", { paths: word("docs") }, FakeCodebaseShell.new) }
        .to raise_error(failure, /no Ruby file under docs/)
    end
  end
end
