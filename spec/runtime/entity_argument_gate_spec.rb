require "spec_helper"

# H1 (docs/audits/2026-08-10-main-bug-audit.md) — an entity command used to
# run NEITHER `refuse_unknown_arguments` NOR `refuse_absent_arguments` at
# all, on a comment claiming it "inherits its aggregate's own gate."
# Nothing on the entity dispatch path ever ran one: a bogus argument was
# accepted outright, and a command that both declares an argument AND
# `sets` a field from it (`Advance`'s own `note`, below) silently wrote
# `nil` over the stored value when that argument was simply omitted —
# persisted data loss, no refusal. `EntityInterpreter` now `include`s the
# same `CommandInterpreter::ArgumentGate` an aggregate command's own dispatch
# already runs (entity_interpreter.rb's own H1 comment), extended with the
# entity chain's own identity heads as addressing (`step_refuse_unknown_
# arguments`'s own comment) so a legitimate dispatch — which must supply the
# entity's own identity (`sequence:`, here) alongside the root's (`label:`)
# — is never mistaken for an unknown argument.
RSpec.describe "an entity command's own argument gate" do
  DISPATCH_ORDER = File.join(InMemoryDomain::ROOT, "spec/fixtures/dispatch_order.bluebook")

  def boot
    @registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(@registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(DISPATCH_ORDER)
    end
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(@registry))
  end

  def open_widget(runtime)
    runtime.dispatch("DispatchOrder::Widget.Open", label: { value: "w1" }, amount: { value: 1 },
                     part_sequence: { value: 1 }, part_note: { value: "first" })
  end

  it "refuses an argument the entity command does not declare" do
    runtime = boot
    open_widget(runtime)

    expect {
      runtime.dispatch("DispatchOrder::Widget.Part.Advance", label: { value: "w1" }, sequence: { value: 1 },
                       note: { value: "moved" }, bogus_arg: 123)
    }.to raise_error(Hecks::Runtime::UnknownArgument, /bogus_arg/)
  end

  it "refuses a declared argument that was simply left out, rather than silently nil-ing the field it sets" do
    runtime = boot
    open_widget(runtime)

    expect {
      runtime.dispatch("DispatchOrder::Widget.Part.Advance", label: { value: "w1" }, sequence: { value: 1 })
    }.to raise_error(Hecks::Runtime::AbsentArgument, /note/)

    # THE REGRESSION ITSELF — confirm the refusal actually happened before
    # any mutation, not just that SOME exception was raised. Before this
    # fix, the dispatch above was accepted and overwrote `parts[0].note`
    # with nil (`sets :note`'s bare self-referential form reads
    # `args[:note]` unconditionally).
    widget = @registry.bluebook("DispatchOrder").aggregates.find { |a| a.hecks_name == "Widget" }
    repo = @registry.repository("DispatchOrder", widget)
    expect(repo.find("w1").state[:parts].first[:note].value).to eq("first")
  end

  it "does not mistake the entity's own identity, or the root's, for an unknown argument" do
    runtime = boot
    open_widget(runtime)

    expect {
      runtime.dispatch("DispatchOrder::Widget.Part.Advance", label: { value: "w1" }, sequence: { value: 1 },
                       note: { value: "moved" })
    }.not_to raise_error
  end

  it "still refuses an unknown argument on a command that transitions nothing" do
    runtime = boot
    open_widget(runtime)

    expect {
      runtime.dispatch("DispatchOrder::Widget.Part.Touch", label: { value: "w1" }, sequence: { value: 1 },
                       note: { value: "touched" }, sneaky: "x")
    }.to raise_error(Hecks::Runtime::UnknownArgument, /sneaky/)
  end
end
