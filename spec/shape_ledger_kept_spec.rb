require "spec_helper"
require_relative "support/kept_worlds"

# `kept?`: one answer, from the committed world, that the target IR exports for the Rust host.
RSpec.describe Hecks::ShapeLedger::Kept do
  include KeptWorlds

  after { remove_kept_directory }

  it "keeps an era-managed store", :aggregate_failures do
    write_shop("PostgresEra")

    expect(ruby_keeps?).to be(true)
    expect(ir_keeps?).to be(true)
  end

  it "does not keep an era-managed store the world marks disposable", :aggregate_failures do
    write_shop("PostgresEra", world: %(  persisted_by("PostgresEra") { disposable_ledger true }))

    expect(ruby_keeps?).to be(false)
    expect(ir_keeps?).to be(false)
  end

  it "does not keep a Memory store", :aggregate_failures do
    write_shop("Memory")

    expect(ruby_keeps?).to be(false)
    expect(ir_keeps?).to be(false)
  end

  it "does not keep a store only a local overlay opts into Postgres", :aggregate_failures do
    write_shop("Memory", local: %(  persisted_by("Postgres") { url "postgres://localhost/x" }))

    expect(ruby_keeps?).to be(false)
    expect(ir_keeps?).to be(false)
  end

  it "keeps a framework member whatever its store" do
    expect(Hecks::Framework.members.keys.map { |name| described_class.of?(nil, name, nil) }.uniq).to eq([true])
  end
end
