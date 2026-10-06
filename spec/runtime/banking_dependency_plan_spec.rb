require "spec_helper"

RSpec.describe "Banking parent-state dependency inference" do
  def banking_account
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
    end

    registry.bluebook("Banking").aggregate("Account")
  end

  let(:account) { banking_account }
  let(:debit) { account.command("Debit") }
  let(:plan) { Hecks::Runtime::DependencyPlanning::Analyzer.call(aggregate: account, command: debit) }

  it "keeps Account.Debit's parent facts out of the caller inputs", :aggregate_failures do
    expect(debit.attributes.map(&:name)).to eq(%i[amount narrative])
    expect(plan.payload_read_set).to eq(%i[amount narrative])
  end

  it "reads and writes the parent facts Account.Debit depends on", :aggregate_failures do
    expect(plan.write_set).to eq(%i[balance ledger])
    expect(plan.read_set).to include(:balance, :daily_limit, :ledger, :status)
    expect(plan.unresolved_dependencies).to eq([])
  end

  it "plans a load-apply-validate-store strategy for the state-dependent command", :aggregate_failures do
    expect(plan).not_to be_state_independent
    expect(plan.strategy_for(capabilities: [:atomic_put])).to eq(:load_apply_validate_store)
  end
end
