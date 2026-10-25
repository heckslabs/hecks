require "spec_helper"

# A copy's own overlay (`environments/local.*`) loads after the domain's files and before a named
# environment, so one copy can name its own database and `HECKS_ENVIRONMENT=memory` still wins.
RSpec.describe Hecks::Adapters::Folder do
  let(:folder) { described_class.new }
  let(:loaded) { [] }

  before { allow(folder).to receive(:load_each) { |_dir, patterns| loaded.concat(patterns) } }

  it "loads the local overlay when no environment is named" do
    folder.load_overlay("/domain", nil)
    expect(loaded).to eq(%w[environments/local.hecksagon environments/local.world])
  end

  it "loads the local overlay first, then the named environment" do
    folder.load_overlay("/domain", "memory")
    expect(loaded).to eq(%w[environments/local.hecksagon environments/local.world
                            environments/memory.hecksagon environments/memory.world])
  end

  it "loads the local overlay once when the environment is local" do
    folder.load_overlay("/domain", "local")
    expect(loaded).to eq(%w[environments/local.hecksagon environments/local.world])
  end
end
