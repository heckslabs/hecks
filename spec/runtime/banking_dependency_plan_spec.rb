require "spec_helper"

RSpec.describe "Banking parent-state dependency inference" do
  def banking_account
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
    end

    registry.bluebook("Banking").aggregate("Account")
  end

  it "reads Account.Debit's parent facts without turning them into caller inputs" do
    account = banking_account
    debit = account.command("Debit")
    plan = Hecksagain::Runtime::DependencyPlanning::Analyzer.call(aggregate: account, command: debit)

    expect(debit.attributes.map(&:name)).to eq(%i[amount narrative])
    expect(plan.payload_read_set).to eq(%i[amount narrative])
    expect(plan.write_set).to eq(%i[balance ledger])
    expect(plan.read_set).to include(:balance, :daily_limit, :ledger, :status)
    expect(plan.unresolved_dependencies).to eq([])
    expect(plan).not_to be_state_independent
    expect(plan.strategy_for(capabilities: [:atomic_put])).to eq(:load_apply_validate_store)
  end
end
