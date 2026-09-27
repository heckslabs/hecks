require "spec_helper"

# The Ruby builder accepts any `provides` key and checks it against CONTRACTS, but the Rust
# parser accepts only grammar-declared keys, so a key missing from the grammar parses in Ruby only.
RSpec.describe "capability contracts and the language grammar" do
  let(:grammar) { File.read(File.expand_path("../lib/hecks/language/bluebook/bluebook.bluebook", __dir__)) }

  let(:declared_keys) do
    grammar.scan(/member keyword: "provides",\s+context: "Bluebook", at: "",\s+named: "(\w+)"/).flatten
  end

  it "declares every key of every capability contract as a `provides` argument" do
    contract_keys = Hecks::Bluebook::Capabilities::CONTRACTS.values.flat_map(&:keys).map(&:to_s).uniq

    expect(contract_keys - declared_keys).to eq([])
  end

  it "declares no `provides` argument that no capability contract uses" do
    contract_keys = Hecks::Bluebook::Capabilities::CONTRACTS.values.flat_map(&:keys).map(&:to_s).uniq

    expect(declared_keys.uniq - contract_keys).to eq([])
  end
end
