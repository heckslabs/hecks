require "spec_helper"
require "hecks/fuzzing"
require_relative "../support/postgres_probe"

# A bulk run carried out as one statement answers, leaves and emits what the same run sent row by
# row does (ADR 0129). The property replays one generated Lamps history twice and compares the two
# after every command-and-query pair, on SQLite and, when one answers, on Postgres.
RSpec.describe "Fuzzing::Properties.set_transform_matches_row_by_row" do
  let(:lamps) { File.join(InMemoryDomain::ROOT, "spec/fixtures/set_transform") }

  def steps(adapter) = Hecks::Fuzzing::SequenceGenerator.generate(lamps, seed: 5, steps: 30, adapter: adapter)

  def parity(adapter) = Hecks::Fuzzing::Properties.set_transform_matches_row_by_row(lamps, steps(adapter), adapter: adapter)

  it "holds for a generated history on SQLite" do
    expect(parity(:sqlite)).to be(true)
  end

  it "compares runs that did go as one statement" do
    allow(Hecks::Bulk::SetSweep).to receive(:new).and_call_original
    parity(:sqlite)
    expect(Hecks::Bulk::SetSweep).to have_received(:new).at_least(4).times
  end

  it "names the pair when the statement answers differently from row by row" do
    allow(Hecks::Bulk::SetSweep).to receive(:new).and_wrap_original do |original, *args|
      original.call(*args).tap { |sweep| allow(sweep).to receive(:outcomes).and_return([]) }
    end
    expect(parity(:sqlite)).to match(/over Lamps::Lamp\..*as one statement a bulk run answered \[\]/)
  end

  it "does not apply to a store without set_transform" do
    expect(Hecks::Fuzzing::Properties.set_transform_matches_row_by_row(lamps, [], adapter: :memory)).to be(true)
  end

  describe "on Postgres", :io do
    it "holds for a generated history" do
      skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

      expect(parity(:postgres)).to be(true)
    end
  end
end
