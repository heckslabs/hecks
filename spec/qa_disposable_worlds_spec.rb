require "hecks"
require "hecks/hecks/adapters/settings_reading"
require_relative "../lib/hecks/quality_control/adapters/main_maintenance"

# The QA bundle's worlds declare their PostgresRevisions ledgers disposable, so a shape change needs no
# mint, and a Maintenance mint of that ledger answers that none is needed instead of erroring.
RSpec.describe "the QA ledger's disposable worlds" do
  let(:ledger) { File.expand_path("../qa/bluebook", __dir__) }

  %w[quality_control fixer governance].each do |name|
    it "declares disposable_ledger true in #{name}.world", :aggregate_failures do
      text = File.read(File.join(ledger, "#{name}.world"))
      block = text[/persisted_by\("Postgres"\) do\n(.*?)\n  end/m, 1]
      expect(block).to match(/^\s*disposable_ledger true$/)
    end
  end

  it "reads the setting as declared for the ledger the QA bundle boots" do
    expect(Hecks::Adapters::QaRevisionMint.disposable?(ledger)).to be(true)
  end

  it "shows it in hecks config, from the world" do
    text = Hecks::Adapters::SettingsReading.new.settings(domain: { value: ledger }).fetch(:text)
    expect(text.lines.map(&:chomp)).to include(a_string_matching(/\Adisposable ledger: yes: .* \(world\)\z/))
  end

  it "answers a mint of the ledger as disposable, without opening a connection", :aggregate_failures do
    expect(Hecks::Adapters::QaRevisionMint.call(ledger, domain: "QualityControl", era: 14, request: { confirm: true },
ledger: ledger))
      .to eq([Hecks::Adapters::QaRevisionMint::DISPOSABLE, false])
    expect(Hecks::Adapters::QaRevisionMint::DISPOSABLE).to start_with("disposable, no mint needed")
  end

  it "refuses the Maintenance mint of the ledger by that answer, before any rule reads it" do
    port = Hecks::Adapters::MainMaintenance.new(root: File.expand_path("../..", ledger))
    expect do
      port.mint(run: "r1", domain: "QualityControl", era: 14, sha: "a" * 40, branch: "qa/x", watermark: 7,
                rehearsal_verdict: "would_mint", confirm: { value: true })
    end.to raise_error(Hecks::Runtime::WiringError, /disposable, no mint needed/)
  end
end
