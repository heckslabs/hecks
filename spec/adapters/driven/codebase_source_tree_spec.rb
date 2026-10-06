require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/codebase/source_tree"

RSpec.describe Hecks::Adapters::SourceTree do
  subject(:adapter) { described_class.new }

  after { Hecks::Adapters::Codebase::Tree.root = nil }

  it "reports that this repository is a checkout" do
    expect(adapter.examine).to eq(checkout: { value: true })
  end

  context "without the gemspec in the tree" do
    around do |example|
      Dir.mktmpdir do |dir|
        Hecks::Adapters::Codebase::Tree.root = dir
        example.run
      end
    end

    it "reports that it is not a checkout" do
      expect(adapter.examine).to eq(checkout: { value: false })
    end

    it "refuses to carry anything out outside a checkout" do
      expect { adapter.perform(operation: { value: "project_model" }) }
        .to raise_error(Hecks::Runtime::GivenNotMet, /needs a hecks checkout/)
    end

    it "refuses to answer a query outside a checkout" do
      expect { adapter.word_status }.to raise_error(Hecks::Runtime::GivenNotMet, /needs a hecks checkout/)
    end
  end

  it "refuses an operation no task family carries out" do
    expect { adapter.perform(operation: { value: "no_such_operation" }) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no task carries out/)
  end
end
