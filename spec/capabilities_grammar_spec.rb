require "spec_helper"

# `provides` takes one named argument per capability key. The Ruby builder
# accepts any key (`**verbs`) and holds it to `Capabilities::CONTRACTS`, but
# the Rust parser only accepts the keys the language's own grammar declares
# (lib/hecks/language/bluebook/bluebook.bluebook, projected to
# rust/parser/src/keywords.rs). A capability added to CONTRACTS without its
# keys in the grammar parses fine in Ruby and is refused by hecks-parse, which
# only shows up once a corpus chapter declares it. This holds the two together.
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
