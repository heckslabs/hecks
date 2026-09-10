require "spec_helper"

# qa/stress_domains/waybill — see its own NOTES.md and the header comment
# on waybill.bluebook for why this domain exists: the first
# `process_manager` (saga) anywhere in this corpus to `dispatch` into a
# NESTED ENTITY's own command, rather than a plain aggregate's — a
# combination absent from every existing saga (banking's own
# Onboarding/Settlement/ExternalSettlement, quality_control's own
# BugCiWatch) and from `qa/stress_domains/nested_pieces` (which proves
# entity nesting fuzzes correctly, but never through a saga's own
# dispatch).
#
# BUG#6, FOUND AND FIXED — the combination did not work the first time
# this domain ran it, for two compounding reasons in shared runtime
# dispatch code, neither one specific to this domain:
#
#   1. `SagaInterpreter#qualified` could not tell a same-domain entity
#      command reference (`Manifest::Slot::Fill`) apart from a genuinely
#      cross-domain one (`Banking::Account::Debit`) — both leave exactly
#      one `::` behind `Naming.command_ref`'s own rewrite — and picked
#      the cross-domain reading unconditionally, so the dispatch never
#      got prefixed with this chapter's own domain at all. Fixed by
#      dropping the guess entirely: a saga dispatch is now always
#      qualified against its own home domain, unconditionally — the
#      same default `PolicyInterpreter#deliver` already applies when no
#      explicit `across` names a different one, and the only reading
#      that was ever actually correct: confirmed against the ENTIRE
#      corpus, no saga anywhere dispatches genuinely cross-domain.
#
#   2. Once (1) resolved the verb correctly, `ReactionInvocation.build`
#      still could not resolve the manifest's own receiver identity for
#      an entity-owned dispatch: `source_receiver_for` refused to lift
#      an inherited aggregate identity at all once a target carried any
#      entities, and separately misread `target.command.creates?` — true
#      for EVERY entity command by construction (`Behaviour::Command
#      #creates?`'s own comment), not only a genuinely creating one —
#      as a reason to refuse. Both were dead code paths until this
#      domain exercised them for the first time; neither is specific to
#      sagas (the same helper backs `PolicyInterpreter#deliver`).
#
# See `lib/hecks/runtime/saga_interpreter.rb`'s `qualified` and
# `lib/hecks/runtime/reaction_invocation.rb`'s `source_receiver_for` for
# the full fix and reasoning. The three specs below now pin the CORRECT,
# fixed behavior — no change to this domain's own bluebook was needed;
# it was correctly authored from the start.
RSpec.describe "Waybill" do
  WAYBILL_ROOT = File.join(InMemoryDomain::ROOT, "qa/stress_domains/waybill/bluebook").freeze

  def boot_waybill
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(WAYBILL_ROOT, "waybill.bluebook"))

      Hecks.hecksagon "Waybill" do
        uses_framework "Governance"

        Waybill::Consignment.persisted_by("Memory")
        Waybill::Manifest.persisted_by("Memory")
      end
    end

    registry.verify!
    runtime = Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    [runtime, registry]
  end

  let(:booted) { boot_waybill }
  let(:runtime) { booted.first }
  let(:registry) { booted.last }

  it "opens a manifest and reserves a slot through the saga's own aggregate-level dispatches — those work" do
    runtime
    Waybill::Consignment.request!(reference: { value: "C1" }, number: { value: 1 }, item: { text: "widget" })

    manifest = Waybill::Manifest.find("C1")
    expect(manifest[:slots].map { |slot| slot[:number][:value] }).to eq([1])

    delivered = registry.saga_log.select { |entry| entry[:dispatch] }.to_h { |entry| [entry[:dispatch], entry[:delivered]] }
    expect(delivered["Manifest.Open"]).to be(true)
    expect(delivered["Manifest.AddSlot"]).to be(true)
  end

  # THE FINDING ITSELF, NOW FIXED. `Manifest::Slot.Fill` — a legitimately
  # declared, correctly addressed entity command — delivers, and the slot
  # it fills actually holds the item afterward.
  it "delivers Manifest::Slot.Fill — the saga's own entity-command dispatch works" do
    runtime
    Waybill::Consignment.request!(reference: { value: "C1" }, number: { value: 1 }, item: { text: "widget" })

    fill_attempt = registry.saga_log.find { |entry| entry[:dispatch] == "Manifest::Slot.Fill" }
    expect(fill_attempt).not_to be_nil
    expect(fill_attempt[:delivered]).to be(true)

    manifest = Waybill::Manifest.find("C1")
    expect(manifest[:slots].first[:item][:text]).to eq("widget")
  end

  # THE DOWNSTREAM CONSEQUENCE — because leg 3 now delivers, the saga
  # actually reaches its own happy path: `ConsignmentShipped` (this
  # process manager's own `ends_on`) fires, and the `:refused` leg
  # (compensation/cancellation) never runs at all. Asserting THIS, not
  # merely the raw delivery above, is what makes this a real end-to-end
  # regression pin rather than an isolated unit fact.
  it "ships the consignment — the saga's happy path (ConsignmentShipped) is reachable" do
    runtime
    Waybill::Consignment.request!(reference: { value: "C1" }, number: { value: 1 }, item: { text: "widget" })

    expect(Waybill::Consignment.find("C1")[:status]).to eq("shipped")

    ship = registry.saga_log.find { |entry| entry[:dispatch] == "Consignment.Ship" }
    expect(ship[:delivered]).to be(true)
    expect(registry.saga_log.none? { |entry| entry[:dispatch] == "Consignment.Cancel" }).to be(true)
  end
end
