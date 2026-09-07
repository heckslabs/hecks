require "spec_helper"

# CommandBuilder#delegates_to_impl's own comment has the full reasoning —
# this proves the runtime side: CommandInterpreter#step_delegate_to_entity
# actually gives synchronous refusal propagation and atomic all-or-nothing
# persistence, the two properties neither `trigger` nor a saga's own
# `dispatches` can give (both commit the triggering command first and
# rescue the target's own refusal). See spec/word_coverage_spec.rb's own
# EXEMPT entry for `delegates_to` — this file is that word's real,
# running, dispatch-level coverage.
RSpec.describe "an aggregate command that delegates_to one nested entity command" do
  DELEGATES_TO_FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/delegates_to/delegates_to.bluebook")
  # A SEPARATE FIXTURE, with no `.hecksagon` — see its own header for why a
  # declared `role` cannot live in the fixture next door.
  DELEGATES_TO_ROLE_FIXTURE = File.join(InMemoryDomain::ROOT,
                                        "spec/fixtures/delegates_to_role/delegates_to_role.bluebook")

  def boot_role
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(DELEGATES_TO_ROLE_FIXTURE)
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  def role_placed(name)
    runtime = boot_role
    runtime.dispatch("DelegatesToRole::Board.OpenBoard", name: { value: name })
    runtime.dispatch("DelegatesToRole::Board.PlacePiece", name: name, id: { value: "p1" },
                                                          square: { file: 3, rank: 3 })
    runtime
  end

  def role_square(runtime, name:)
    board = runtime.registry
                   .repository("DelegatesToRole", runtime.registry.bluebook("DelegatesToRole").aggregate("Board"))
                   .find(name)
    board[:pieces].first[:square]
  end

  def boot
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(DELEGATES_TO_FIXTURE)
      Hecks::Runtime::Loader.bind_runtime(
        Hecks::Runtime::Dispatcher.new(registry)
      )
    end
  end

  # `.first`, not a `find` matched on id — one piece per board is all any
  # example here needs, and it sidesteps having to know whether a stored
  # id round-trips as a bare String or a wrapped one-field Value.
  def square(runtime, name:)
    board = runtime.registry.repository("DelegatesTo", runtime.registry.bluebook("DelegatesTo").aggregate("Board"))
                   .find(name)
    board[:pieces].first[:square]
  end

  it "mutates the target entity and emits its own event, in ONE dispatch that never names the entity" do
    runtime = boot
    runtime.dispatch("DelegatesTo::Board.OpenBoard", name: { value: "b1" })
    runtime.dispatch("DelegatesTo::Board.PlacePiece", name: "b1", id: { value: "p1" }, square: { file: 3, rank: 3 })

    result = runtime.dispatch("DelegatesTo::Board.MovePiece", to: "b1", with: { id: { value: "p1" }, to: { file: 5, rank: 5 } })

    expect(result.events.map(&:name)).to eq(["PieceMoved"])
    expect(square(runtime, name: "b1").to_h).to eq(file: 5, rank: 5)
  end

  # A REAL BUG, found live building this fixture's own downstream
  # consumer (a chess domain): `with:` only remaps what it names, and a
  # first draft of `step_delegate_to_entity` built `target_args` from
  # `with:` ALONE — so a policy reacting to the delegated command's own
  # emitted event, trying to re-locate Board by its own identity
  # (`name`, never named in `with: { id:, to: }`), found nothing and its
  # reaction was rescued and recorded rather than raised (the same
  # commit-then-react shape every OTHER policy reaction has). Fixed by
  # starting `target_args` from a copy of the delegating command's own
  # already-resolved args, so ambient context a caller never had to
  # name explicitly still flows through, same as a direct entity
  # dispatch always would.
  it "carries the delegating command's own ambient args through to the target's own emitted event" do
    runtime = boot
    runtime.dispatch("DelegatesTo::Board.OpenBoard", name: { value: "b4" })
    runtime.dispatch("DelegatesTo::Board.PlacePiece", name: "b4", id: { value: "p1" }, square: { file: 3, rank: 3 })

    runtime.dispatch("DelegatesTo::Board.MovePiece", to: "b4", with: { id: { value: "p1" }, to: { file: 5, rank: 5 } })

    board = runtime.registry.repository("DelegatesTo", runtime.registry.bluebook("DelegatesTo").aggregate("Board"))
                   .find("b4")
    expect(board[:move_count].to_h).to eq(value: 1)
  end

  it "raises the target's own refusal AS the delegating command's own refusal — synchronously, not recorded and swallowed" do
    runtime = boot
    runtime.dispatch("DelegatesTo::Board.OpenBoard", name: { value: "b2" })
    runtime.dispatch("DelegatesTo::Board.PlacePiece", name: "b2", id: { value: "p1" }, square: { file: 3, rank: 3 })

    expect do
      runtime.dispatch("DelegatesTo::Board.MovePiece", to: "b2", with: { id: { value: "p1" }, to: { file: 3, rank: 3 } })
    end.to raise_error(Hecks::Runtime::GivenNotMet, /destination differs from current square/)
  end

  it "persists nothing from a refused delegation — the failed attempt leaves the piece exactly where it was" do
    runtime = boot
    runtime.dispatch("DelegatesTo::Board.OpenBoard", name: { value: "b3" })
    runtime.dispatch("DelegatesTo::Board.PlacePiece", name: "b3", id: { value: "p1" }, square: { file: 3, rank: 3 })

    begin
      runtime.dispatch("DelegatesTo::Board.MovePiece", to: "b3", with: { id: { value: "p1" }, to: { file: 3, rank: 3 } })
    rescue Hecks::Runtime::GivenNotMet
      nil
    end

    expect(square(runtime, name: "b3").to_h).to eq(file: 3, rank: 3)
  end

  # THE TARGET COMMAND'S OWN GATES — `CommandInterpreter#step_delegate_to_entity`'s
  # own comment has the full reasoning and names which three declared steps it
  # deliberately still does not run. Both gaps below were REPRODUCED before
  # they were fixed: a `Clerk` refused by `Piece.Retire` directly was admitted
  # through `RetirePiece`, and `RetirePieceForgettingReason` succeeded with a
  # required argument silently absent.
  #
  # EACH PAIRS WITH A DIRECT-DISPATCH CONTROL, deliberately: without one, a
  # passing example only proves *something* refused, not that delegation stopped
  # skipping the gate.
  def placed(name)
    runtime = boot
    runtime.dispatch("DelegatesTo::Board.OpenBoard", name: { value: name })
    runtime.dispatch("DelegatesTo::Board.PlacePiece", name: name, id: { value: "p1" },
                                                      square: { file: 3, rank: 3 })
    runtime
  end

  it "CONTROL: the role-guarded entity command refuses a wrong-role caller dispatched directly" do
    runtime = role_placed("r1")
    expect do
      Hecks.as_caller(role: "Clerk") do
        runtime.dispatch("DelegatesToRole::Board.Piece.Retire", name: "r1", id: { value: "p1" },
                                                                destination: { file: 5, rank: 5 })
      end
    end.to raise_error(Hecks::Runtime::Unauthorized)
  end

  it "runs the TARGET command's own role check — a wrong-role caller is refused through the door too" do
    runtime = role_placed("r2")
    expect do
      Hecks.as_caller(role: "Clerk") do
        runtime.dispatch("DelegatesToRole::Board.RetirePiece",
                         to: "r2", with: { id: { value: "p1" }, destination: { file: 5, rank: 5 } })
      end
    end.to raise_error(Hecks::Runtime::Unauthorized)
  end

  it "still admits the RIGHT role through the door — the gate refuses, it does not block everything" do
    runtime = role_placed("r3")
    Hecks.as_caller(role: "Supervisor") do
      runtime.dispatch("DelegatesToRole::Board.RetirePiece",
                       to: "r3", with: { id: { value: "p1" }, destination: { file: 5, rank: 5 } })
    end
    expect(role_square(runtime, name: "r3").to_h).to eq(file: 5, rank: 5)
  end

  it "runs the TARGET command's own required-argument check — a door that never maps one is refused" do
    runtime = placed("r4")
    expect do
      runtime.dispatch("DelegatesTo::Board.RetirePieceForgettingReason",
                       to: "r4", with: { id: { value: "p1" }, destination: { file: 5, rank: 5 } })
    end.to raise_error(Hecks::Runtime::AbsentArgument, /reason/)
  end

  # THE EXCLUSION, PINNED. `refuse_unknown_arguments` must NOT run here: the
  # delegating command's own args are merged into `target_args` on purpose, so
  # running it would refuse every real delegation. This is the existing
  # `MovePiece` path — `name` is ambient, `Piece.Move` never declares it.
  it "does NOT refuse the ambient args a delegating command passes through" do
    runtime = placed("r5")
    result = runtime.dispatch("DelegatesTo::Board.MovePiece",
                              to: "r5", with: { id: { value: "p1" }, to: { file: 5, rank: 5 } })
    expect(result.events.map(&:name)).to eq(["PieceMoved"])
  end
end
