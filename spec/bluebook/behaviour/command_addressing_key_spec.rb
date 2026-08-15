
require "spec_helper"

# `Behaviour::Command#addressing_key_for` — the fix for a real bug found
# wiring `for_each` into banking (this session's own property-testing
# arc): a fan-out dispatch used to mint `<aggregate>_id` for every
# target command UNCONDITIONALLY, which refuses every dispatch to a
# command declared ON the very aggregate it self-references
# (`Account.FreezeAccount`, addressed by `account`/its own identity, never a
# synthetic foreign key).
#
# PINNED AGAINST REAL BANKING COMMANDS DIRECTLY — no fixture, no
# dispatch, no policy, no `for_each` wiring anywhere in this file. The
# regression this method fixes is real and general (it's asked of ANY
# resolved target command, by name, whether or not any policy in the
# current corpus actually exercises it via `for_each` today — see
# banking.bluebook's own comment on `FreezeAccountsOnSuspension` for
# why `for_each` itself isn't wired into a real banking policy right
# now, independent of this fix's own correctness).
RSpec.describe "Behaviour::Command#addressing_key_for" do
  def bluebook
    return @bluebook if @bluebook

    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))
    end
    @bluebook = registry.bluebook("Banking")
  end

  it "mints the SELF-ADDRESSING key for a command declared on the very aggregate it references" do
    freeze = bluebook.aggregate("Account").command("FreezeAccount")

    # `Account.FreezeAccount` declares `reference_to Account` with no `as:` —
    # it self-references its own owning aggregate. The OLD, buggy mint
    # (`Naming.reference_key("Account") + "_id"`) would have answered
    # `:account_id`, which `Account.FreezeAccount` — declaring zero attributes
    # of its own — refuses; Account's OWN identity field is `number`,
    # not `account_id` either. `:account` is the one key
    # `CommandInterpreter::ArgumentGate#reference_key` already accepts
    # for exactly this command.
    expect(freeze.addressing_key_for("Account")).to eq(:account)
  end

  it "mints the CROSS-REFERENCING key — the attribute's own declared name — for a command on a different aggregate" do
    open = bluebook.aggregate("Account").command("Open")

    # `Account.Open` is declared on Account but references Customer — a
    # real, minted foreign-key attribute (`customer`, bare — ADR 0025),
    # not a self-reference. The key is the ATTRIBUTE's own name, exactly
    # as declared, never re-derived from the target's own name (which
    # matters the moment an `as:` reference's name legitimately differs
    # from the target's snake case, e.g. Transfer's own `source`/
    # `destination`, both `Reference<Account>`).
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
