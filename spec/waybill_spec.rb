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
# FIRST REAL TRY, FIRST REAL FINDING: the combination does not work
# today. `SagaInterpreter#qualified` cannot distinguish a same-domain
# entity command reference from a genuinely cross-domain one — both
# leave exactly one `::` behind `Naming.command_ref`'s own rewrite — and
# picks the wrong reading, so `Manifest::Slot.Fill` is dispatched
# UNPREFIXED and `ReactionInvocation.resolve_target` reads "Manifest" as
# a domain name rather than this chapter's own aggregate. The three
# specs below are a DEMONSTRATION, not a regression pin: they assert the
# CURRENT (broken) behavior, on purpose, so this file itself is the
# reproduction a future fix's own regression test replaces — see the
# bluebook's own header comment for the exact mechanism and NOTES.md for
# the full write-up this domain's authoring session hands off to whoever
# holds `qa/bluebook/quality_control.bluebook`'s own ledger next.
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

  # THE FINDING ITSELF. `Manifest::Slot.Fill` — a legitimately declared,
  # correctly addressed entity command — refuses every time, purely
  # because of how the saga's own dispatch reference gets qualified, not
  # because of anything about `number`/`item`. `SagaInterpreter#qualified`
  # reads the ONE surviving `::` left by `Naming.command_ref`'s rewrite of
  # `Manifest::Slot::Fill` as "already domain-qualified" and never
  # prefixes it with `Waybill::` at all — so `Naming.split_verb` goes on
  # to read "Manifest" as a DOMAIN name (there is none) rather than this
  # chapter's own aggregate, and `ReactionInvocation.resolve_target`
  # raises `UnknownVerb`, which the saga interpreter (correctly, by its
  # own lights — see `errors.rb`'s own comment on why `UnknownVerb` is a
  # domain refusal) records as an ordinary refusal rather than a defect.
  it "refuses Manifest::Slot.Fill every time — an entity-command saga dispatch never delivers" do
    runtime
    Waybill::Consignment.request!(reference: { value: "C1" }, number: { value: 1 }, item: { text: "widget" })

    fill_attempt = registry.saga_log.find { |entry| entry[:dispatch] == "Manifest::Slot.Fill" }
    expect(fill_attempt).not_to be_nil
    expect(fill_attempt[:delivered]).to be(false)
    expect(fill_attempt[:reason]).to eq('reaction target "Manifest::Slot.Fill" does not resolve to an aggregate')

    # THE SLOT ITSELF NEVER ACTUALLY FILLS — the manifest still holds the
    # slot bare, no `item` ever set, confirming the refusal is real (not
    # merely mis-logged) at the level a modeler would actually check.
    manifest = Waybill::Manifest.find("C1")
    expect(manifest[:slots].first[:item]).to be_nil
  end

  # THE DOWNSTREAM CONSEQUENCE — because leg 3 always refuses, the saga's
  # own `:refused` leg is, right now, the ONLY leg this saga can ever
  # reach past "filling": `ConsignmentShipped` (this process manager's
  # own `ends_on`) is an unreachable happy path until the underlying gap
  # closes. Asserting THIS, not merely the raw refusal above, is what
  # makes this a real end-to-end demonstration rather than an isolated
  # unit fact about `SagaInterpreter#qualified`.
  it "always cancels the consignment — the saga's happy path (ConsignmentShipped) is unreachable today" do
    runtime
    Waybill::Consignment.request!(reference: { value: "C1" }, number: { value: 1 }, item: { text: "widget" })

    expect(Waybill::Consignment.find("C1")[:status]).to eq("cancelled")

    cancel = registry.saga_log.find { |entry| entry[:dispatch] == "Consignment.Cancel" }
    expect(cancel[:delivered]).to be(true)
    expect(registry.saga_log.none? { |entry| entry[:dispatch] == "Consignment.Ship" }).to be(true)
  end
end
