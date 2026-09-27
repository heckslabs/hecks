require "spec_helper"

# Pins that a fan-out dispatch addresses a self-referencing command by the aggregate's own
# identity (`Account.FreezeAccount` -> `:account`), never a synthetic `<aggregate>_id` key.
# Runs against the real banking commands directly; no dispatch or policy is involved.
RSpec.describe "Behaviour::Command#addressing_key_for" do
  def bluebook
    return @bluebook if @bluebook

    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
    end
    @bluebook = registry.bluebook("Banking")
  end

  it "mints the SELF-ADDRESSING key for a command declared on the very aggregate it references" do
    freeze = bluebook.aggregate("Account").command("FreezeAccount")

    # `FreezeAccount` self-references Account and declares no attributes, so `:account_id`
    # is refused; `:account` is the one key `ArgumentGate#reference_key` accepts.
    expect(freeze.addressing_key_for("Account")).to eq(:account)
  end

  it "mints the CROSS-REFERENCING key — the attribute's own declared name — for a command on a different aggregate" do
    open = bluebook.aggregate("Account").command("Open")

    # The key is the reference attribute's declared name, not derived from the target's name,
    # since an `as:` reference (Transfer's `source`/`destination`) can differ.
    expect(open.addressing_key_for("Customer")).to eq(:customer)
  end

  it "answers nil for a creating command — there is no existing row yet to address" do
    register = bluebook.aggregate("Customer").command("Register")

    expect(register.addressing_key_for("Customer")).to be_nil
  end

  it "answers nil when the command genuinely cannot be addressed by an instance of the named aggregate at all" do
    freeze = bluebook.aggregate("Account").command("FreezeAccount")

    expect(freeze.addressing_key_for("Customer")).to be_nil
  end
end
