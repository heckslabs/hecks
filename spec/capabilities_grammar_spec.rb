require "spec_helper"

# The Rust parser accepts only grammar-declared `provides` keys, so the grammar names every key of
# every contract the language defines, and one open row admits the keys a package declares for a
# capability of its own.
RSpec.describe "capability contracts and the language grammar" do
  let(:grammar) { File.read(File.expand_path("../lib/hecks/language/bluebook/bluebook.bluebook", __dir__)) }

  let(:declared_keys) do
    grammar.scan(/member keyword: "provides",\s+context: "Bluebook", at: "",\s+named: "(\w+)"/).flatten
  end

  let(:contract_keys) { Hecks::Bluebook::Capabilities::CONTRACTS.values.flat_map(&:keys).map(&:to_s).uniq }

  it "declares every key of every capability contract as a `provides` argument" do
    expect(contract_keys - declared_keys).to eq([])
  end

  it "declares no named `provides` argument that no capability contract uses" do
    expect(declared_keys.uniq - contract_keys).to eq([])
  end

  it "admits a package's own keys through one open `provides` row" do
    open_rows = grammar.scan(/member keyword: "provides",\s+context: "Bluebook", at: "",\s+named: "",\s+kind: "pairs"/)

    expect(open_rows.size).to eq(1)
  end
end
