require "spec_helper"
require "hecks"

# Binding Postgres without the pg gem installed names the gem, never a constant that only exists
# once it loads.
RSpec.describe "connecting a Postgres adapter without the pg gem" do
  {
    "revision" => Hecks::Adapters::PostgresEra,
    "table"    => Hecks::Adapters::Postgres
  }.each do |layout, adapter|
    it "raises a LoadError from the #{layout} layout that says to add the pg gem" do
      hide_const("PG")
      allow(adapter).to receive(:require).with("hecks/pg_options").and_raise(LoadError, "cannot load such file -- pg")

      expect { adapter.connect_for("Pizzas", { database: "postgres://localhost/x" }) }
        .to raise_error(LoadError, /Pizzas binds Postgres, which needs the pg gem/)
    end
  end
end
