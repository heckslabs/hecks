require "hecks"
require "hecks/ports/persistence/plugins/era"

# Not `io: true`: `setting` touches no database. Pins that a stored `false` at the symbol
# key is not discarded by `||` in favor of the string key, so `key?` must be asked first.
RSpec.describe "Hecks::Adapters::PostgresEra.setting" do
  let(:described_class) { Hecks::Adapters::PostgresEra }

  it "returns a symbol-keyed value that is literally `false`, rather than falling to the string spelling" do
    settings = { database: false, "database" => "elsewhere" }

    expect(described_class.setting(settings, :database)).to be(false)
  end

  it "returns a string-keyed value that is literally `false`, rather than falling to `default`" do
    settings = { "schema" => false }

    expect(described_class.setting(settings, :schema, default: "public")).to be(false)
  end

  it "prefers the symbol spelling over the string spelling when both are present" do
    settings = { domain: "SymbolDomain", "domain" => "StringDomain" }

    expect(described_class.setting(settings, :domain)).to eq("SymbolDomain")
  end

  it "falls to the string spelling only when the symbol key is genuinely absent" do
    settings = { "domain" => "StringDomain" }

    expect(described_class.setting(settings, :domain)).to eq("StringDomain")
  end

  it "falls to `default` only when neither spelling is present at all" do
    expect(described_class.setting({}, :domain, default: "fallback-name")).to eq("fallback-name")
  end

  it "answers nil with no default when neither spelling is present" do
    expect(described_class.setting({}, :era)).to be_nil
  end
end
