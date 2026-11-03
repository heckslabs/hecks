require "spec_helper"
require "json"
require_relative "../support/memory_ports"

# The overall listing opens with a banner line; a query's output, the `--json` listing and a
# command's own `--help` do not carry it, since scripts parse those.
RSpec.describe Hecks::Adapters::Driving::CliRunner do
  let(:runtime) { Hecks.describe(File.expand_path("../../lib/hecks/hecks", __dir__), environment: nil) }
  let(:banner) { "=== HECKS ===" }

  def listing(*argv, program: "hecks") = described_class.usage(runtime: runtime, argv: argv, program: program).first
  def banner_for(program) = listing(program: program).lines.first.chomp

  it "opens the bare listing with the banner line" do
    expect(listing.lines.first.chomp).to eq(banner)
  end

  it "follows the banner with the description line" do
    expect(listing.lines[1]).to start_with("Hecks — ")
  end

  it "opens the --help and --all listings with the banner too" do
    expect([listing("--help"), listing("--all")].map { |text| text.lines.first.chomp }).to eq([banner] * 2)
  end

  it "keeps the banner out of a query's output" do
    text, = described_class.call(runtime: boot_in_memory, argv: %w[query order.available],
                                 program: "hecks")
    expect(text).not_to include(banner)
  end

  it "keeps the banner out of the --json listing, which still parses", :aggregate_failures do
    text = listing("--json")
    expect(text).not_to include(banner)
    expect(JSON.parse(text)).to be_an(Array)
  end

  it "keeps the banner out of a command's own --help" do
    expect(listing("Landing.land!", "--help")).not_to include(banner)
  end

  it "names the banner for the program's first word, as a basename without extension" do
    expect(["hecks run", "banking", "./exe/acme-shop", "pizzas/pizzas", "bin/shop.rb"].map { |p| banner_for(p) })
      .to eq(["=== HECKS ===", "=== BANKING ===", "=== ACME-SHOP ===", "=== PIZZAS ===", "=== SHOP ==="])
  end

  it "falls back to HECKS when the program names nothing" do
    expect(["", " ", nil].map { |program| banner_for(program) }).to eq(["=== HECKS ==="] * 3)
  end

  it "keeps the HECKS banner on an attached bluebook's listing" do
    expect(listing("governance").lines.first.chomp).to eq(banner)
  end
end
