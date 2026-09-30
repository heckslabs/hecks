require "spec_helper"
require "hecks"

# Binding Postgres without the pg gem installed names the gem, never a constant that only exists once it loads.
RSpec.describe "connecting a Postgres adapter without the pg gem" do
  {
    "PostgresEra" => Hecks::Adapters::PostgresEra,
    "Postgres"    => Hecks::Adapters::Postgres
  }.each do |label, adapter|
    it "raises a LoadError from #{label} that says to add the pg gem" do
      hide_const("PG")
      allow(adapter).to receive(:require).with("pg").and_raise(LoadError, "cannot load such file -- pg")

      expect { adapter.connect_for("Pizzas", { database: "postgres://localhost/x" }) }
        .to raise_error(LoadError, /Pizzas binds #{label}, which needs the pg gem/)
    end
  end
end
