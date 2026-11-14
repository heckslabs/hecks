require "spec_helper"
require "hecks/hecks/adapters/main_integration/local_overlay"
require "hecks/adapters/driven/sqlite"

# Each failed attempt of a train pull request's CI is kept, so the failed jobs it recorded are read
# after the rerun that cleared them, by a launcher call other than the one that recorded them.
RSpec.describe "the train pull request's failure record" do
  it "is persisted by the train's overlay" do
    rows = Hecks::Adapters::MainIntegration::KeptRows.from_registry(boot_hecks_in_memory.registry)
    text = Hecks::Adapters::MainIntegration::LocalOverlay.new(Dir.pwd, rows, "train").text
    expect(text).to include("Hecks::TrainPr.persisted_by(\"SqlitePersistence\")")
  end

  # A process that dies between a record and its rerun leaves the reaction in the outbox, so the
  # next boot delivers it instead of refusing the same key as already recorded.
  it "is bound to an adapter with an outbox" do
    methods = Hecks::Ports::Persistence::AppendOnly::OUTBOX_METHODS
    expect(methods.all? { |name| Hecks::Adapters::SqlitePersistence.method_defined?(name) }).to be(true)
  end
end
