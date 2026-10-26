require "spec_helper"
require "hecks/hecks/adapters/codebase/composing"
require "hecks/hecks/adapters/codebase/tree"
require "hecks/composer/workbench"

# `corpus_run.compose`: serves the Composer editor with the agent the run names.
RSpec.describe Hecks::Adapters::Codebase::Composing do
  let(:tree) { Hecks::Adapters::Codebase::Tree.new }

  before do
    allow(Hecks::Adapters::Codebase::CorpusTasks).to receive(:web_server).and_return(->(**) {})
    allow(Hecks::Composer::Workbench).to receive(:agents_named).and_call_original
    allow($stderr).to receive(:write)
  end

  def compose(**fields) = described_class.call("compose", fields.transform_values { |value| { value: value } }, tree)

  it "opens the editor with the scripted agent when the run names `fake`" do
    compose(agent: "fake")

    expect(Hecks::Composer::Workbench).to have_received(:agents_named).with("fake")
  end

  it "opens it with the real agent otherwise" do
    compose

    expect(Hecks::Composer::Workbench).to have_received(:agents_named).with(nil)
  end
end
