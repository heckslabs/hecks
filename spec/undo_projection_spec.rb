require "spec_helper"

# Projector.call(:undo) answers a command's undo from the bluebook's declared compensations.
RSpec.describe "the undo of a declared command" do
  def boot_banking
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
    end
    registry
  end

  let(:banking) { boot_banking.bluebook("Banking") }

  def undo_of(command)
    Hecks::Projector.call(:undo, bluebook: banking, options: { command: command }).join("\n")
  end

  it "names the compensating command for a dispatch the bluebook compensates" do
    expect(undo_of("Account.Debit")).to include("undone by Account.Credit")
  end

  it "says none is declared for a command with no compensation" do
    expect(undo_of("Account.Credit")).to include("has no undo declared")
  end

  it "reads the command in either spelling" do
    expect(undo_of("Account::Debit")).to include("undone by Account.Credit")
  end
end
