require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/fenced_owner"
require_relative "../../../support/era_registry_loading"
require_relative "../../../support/first_era_hold"

# A Maintenance-like aggregate with a mint command that declares `mints_era true` and another
# command that does not: through an unminted boot only the mint command's record is written.
RSpec.describe "a Maintenance-like mint command through an unminted boot", :io do
  include EraRegistryLoading
  include FirstEraHold

  DOOR_DB = "hecks_mint_door_spec".freeze

  scratch_postgres DOOR_DB, fenced: true

  def boot_url = FencedOwner.url(DOOR_DB)

  def shape(field)
    <<~BLUEBOOK
      Hecks.bluebook "Ledger" do
        aggregate "Maintenance" do
          identified_by :run

          attribute :#{field}, Money
          attribute :run, Run

          value_object "Money" do
            attribute :cents, Integer
          end

          value_object "Run" do
            attribute :label, String
          end

          command "MintEra" do
            mints_era true
            attribute :run, Run
            emits "MintRequested"
          end

          command "Note" do
            attribute :run, Run
            emits "Noted"
          end
        end
      end
    BLUEBOOK
  end

  def registry_for(source)
    registry = load_registry(source)
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: registry.bluebooks.values.first, current_text: source,
      settings: { database: boot_url, mint_eras: true }
    )
    registry
  end

  def maintenance(registry) = registry.bluebooks.values.first.aggregate("Maintenance")

  def command_named(registry, name) = maintenance(registry).commands.find { |c| c.hecks_name == name }

  def adapter_for(registry)
    settings = { database: boot_url, domain: "Ledger", era: 1, unminted: true }
    Hecks::Adapters::PostgresEra.new(aggregate: maintenance(registry), settings: settings)
  end

  # The refusal message of the command's record written through the adapter, or nil when it passed.
  def write_error(adapter, command)
    adapter.append(Hecks::Ports::Persistence::Entry.new(
                     operation: "save", id: "run-1", state: { cost: { "cents" => 5 }, run: { "label" => "r" } },
                     mirrors: nil, mints_era: command.mints_era?
                   ))
    nil
  rescue Hecks::Runtime::WiringError => e
    e.message
  end

  let(:unminted) { registry_for(shape("total")) }

  before do
    hold_first_era!(url: boot_url, domain: "Ledger", source: shape("cost"))
    registry_for(shape("cost"))
  end

  it "saves the mints_era command's record through the unminted boot" do
    expect(write_error(adapter_for(unminted), command_named(unminted, "MintEra"))).to be_nil
  end

  it "still refuses the other command's save from the same boot" do
    expect(write_error(adapter_for(unminted), command_named(unminted, "Note"))).to include("not minted yet")
  end
end
