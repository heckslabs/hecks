require "spec_helper"

# `provides` on an adapter, asked through the aggregate it persists: the SQL persistence adapters
# rewrite every row in one statement, and an adapter that never says so provides nothing.
RSpec.describe "what the adapter an aggregate is bound to provides" do
  def ledger_bluebook
    Hecks.bluebook("Ledger") do
      supporting
      aggregate "Entry" do
        identified_by :label
        attribute :label, Label
        value_object "Label", String
        command("Open") { attribute :label, Label }
      end
    end
  end

  def bound_to(adapter)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Hecks::Adapters::Folder.new.load_library
      ledger_bluebook
      Hecks.hecksagon("Ledger") { persisted_by adapter } if adapter
    end
    registry
  end

  it "says Postgres, Sqlite and PostgresEra provide set_transform", :aggregate_failures do
    %w[Postgres SqlitePersistence PostgresEra].each do |adapter|
      expect(bound_to(adapter).adapter_provides?("Ledger", "Entry", "set_transform")).to be(true), adapter
    end
  end

  it "says Memory provides no set_transform, bound or by default", :aggregate_failures do
    expect(bound_to("Memory").adapter_provides?("Ledger", "Entry", :set_transform)).to be(false)
    expect(bound_to(nil).adapter_provides?("Ledger", "Entry", "set_transform")).to be(false)
  end

  it "says no adapter provides a capability nobody declares" do
    expect(bound_to("Postgres").adapter_provides?("Ledger", "Entry", "teleport")).to be(false)
  end

  it "names the bound adapter's declaration" do
    expect(bound_to("Postgres").bound_adapter("Ledger", "Entry").capabilities).to eq(["set_transform"])
  end

  it "refuses an aggregate the domain does not declare" do
    expect { bound_to("Postgres").adapter_provides?("Ledger", "Ghost", "set_transform") }
      .to raise_error(Hecks::Runtime::WiringError, /no aggregate Ghost/)
  end
end
