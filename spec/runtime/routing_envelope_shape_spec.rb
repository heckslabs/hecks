require "spec_helper"

# BUG#7 (found live by `bin/qa_sweep`, `examples/roster` fuzz seed 1,
# step 9 — `Mark`'s 6th refusal in the sequence) — `Routing.envelope`'s
# non-Hash branch used to accept ANY Ruby object as a ready-made
# aggregate identity scalar (`to.is_a?(Hash) ? parse_envelope_hash(to)
# : [to, []]`, unconditionally), looser than Rust's own hand-written
# mirror of this exact boundary (`rust/src/kernel/routing.rs#
# RoutingEnvelope::from_json`), which refuses anything that is neither
# a JSON string nor object outright, TypeMismatch, before a domain's own
# command payload is ever examined.
#
# The gap only surfaces for a domain that declares a command attribute
# literally named `to` — `Roster::Roster.Mark` is the first (deliberate,
# per that bluebook's own header comment) — because `bin/run`/`Hecks::
# Fuzzing::Replay`/`StepBuilder` all dispatch a generated step's flat
# args Hash via `runtime.dispatch(verb, **symbolize(args))`. Ruby's own
# keyword-argument binding steals a `to` key out of that flat Hash into
# `Dispatcher#dispatch`'s own `to:` (ROUTING) parameter before the
# command's own `to:` (DOMAIN) argument is ever assembled — completely
# invisible for every other domain in this corpus, none of which name an
# attribute `to`, `with`, or `saga_correlation`. A fuzzer-corrupted,
# out-of-range Integer offered for `Mark`'s own `to` was accepted here
# unconditionally as the routing target, leaving `Mark`'s required `to`
# fact absent from the payload — Ruby refused `AbsentArgument` ("Mark was
# not given to — it takes to"); Rust's stricter envelope parser refuses
# the malformed scalar itself, TypeMismatch, before the payload is ever
# examined. Tightening the scalar branch to Rust's own contract (a
# non-Hash `to:` must be a `String`) makes both refuse the same way, for
# the same reason, at the same step — without touching the Hash-shaped
# envelope branch, `with:`, or any caller that already hands `to:` a
# real (always string, `Naming.identity`-canonicalized) identity.
RSpec.describe "Routing.envelope's non-Hash branch" do
  ROSTER_BLUEBOOK_DIR = File.join(InMemoryDomain::ROOT, "examples/roster/bluebook").freeze

  def boot_roster
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      InMemoryDomain.load_bluebook_files(ROSTER_BLUEBOOK_DIR)
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  let(:runtime) { boot_roster }

  before { runtime.dispatch("Roster::Roster.Open", name: { value: "juliet india hotel" }) }

  it "refuses a non-string, non-Hash scalar as TypeMismatch, not as an absent domain argument" do
    # Exactly seed 1 / step 9's generated payload — a bare, corrupted,
    # out-of-i64-range Integer for `Mark`'s own `to`, dispatched the same
    # flat-kwargs way `StepBuilder#build_command_step` does
    # (`runtime.dispatch(entry[:verb], **symbolize(args))`), which is
    # exactly what steals a domain-declared `to` into the routing
    # parameter instead of the command payload.
    expect do
      runtime.dispatch("Roster::Roster.Mark",
                       to:   -1_267_650_600_228_229_401_496_703_205_376,
                       name: "juliet india hotel")
    end.to raise_error(Hecks::Runtime::TypeMismatch, /to: must be a string aggregate identity or an entity route/)
  end

  it "still accepts a real string identity for the routing envelope" do
    expect do
      runtime.dispatch("Roster::Roster.Mark", to: "juliet india hotel", with: { to: { value: 5 } })
    end.not_to raise_error
  end

  it "still refuses an unrecognized Hash-shaped envelope key exactly as before" do
    expect do
      runtime.dispatch("Roster::Roster.Mark", to: { value: 0 }, name: "juliet india hotel")
    end.to raise_error(Hecks::Runtime::TypeMismatch, "to: does not recognize value")
  end
end
