require "spec_helper"
require "hecks/composer/toolbox"
require "hecks/composer/agent"

# The intents a prompt can ask for and the palette commands that run unguarded are declared in
# composer.bluebook; the Composer's code reads them and keeps no copy.
RSpec.describe Hecks::Composer::Declared do
  it "gives Agent the declared intents" do
    expect(Hecks::Composer::Agent::INTENTS).to eq(%w[edit wire question new_domain])
  end

  it "gives Toolbox the declared safe commands", :aggregate_failures do
    safe = Hecks::Composer::Toolbox::SAFE_COMMANDS

    expect(safe).to eq(described_class.closed_set("Palette", "SafeCommand"))
    expect(safe).to include("model_check_run.model_check", "operation.run")
  end
end
