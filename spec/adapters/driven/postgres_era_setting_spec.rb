require "hecks"
require "hecks/ports/persistence/plugins/era"

# `PostgresEra.setting` is the shared two-spelling settings digger four
# call sites in postgres_era.rb (database, schema, domain, era) all read
# through — deliberately NOT `io: true`: it touches no database at all,
# so it runs in the ordinary local loop rather than only under Postgres.
#
# The bug this guards against: `settings[:x] || settings["x"]` silently
# discards a genuinely stored `false` at the symbol spelling in favor of
# whatever (or nothing) sits at the string spelling, because `||` cannot
# tell "stored false" apart from "absent". `key?` can, and must be asked
# first.
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
