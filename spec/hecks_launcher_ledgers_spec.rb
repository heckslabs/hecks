require "spec_helper"

# Which command words the launcher routes to a ledger's own directory is declared in
# hecks.world; the rotation's list of ledgers must say the same.
RSpec.describe "the launcher's ledger routes" do
  let(:runtime) { Hecks.boot(File.expand_path("../lib/hecks/hecks", __dir__), install_driving: false) }

  it "are the ones the rotation sweeps" do
    setting = Hecks::Adapters::Driving::LauncherOptions.settings(runtime, "Hecks")

    expect(setting[:ledgers]).to eq(Hecks::Corpus::ROTATION_LEDGER)
  end
end
