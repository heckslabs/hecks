require "spec_helper"

# Dispatch-level coverage of `delegates_to`: synchronous refusal propagation and atomic
# persistence, which `trigger` and a saga's `dispatches` cannot give.
RSpec.describe "an aggregate command that delegates_to one nested entity command" do
  DELEGATES_TO_FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/delegates_to/delegates_to.bluebook")

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

  # `.first`, not a `find` on id: a stored id may round-trip as a String or a wrapped Value.
  def square(runtime, name:)
    board = runtime.registry.repository("DelegatesTo", runtime.registry.bluebook("DelegatesTo").aggregate("Board"))
                   .find(name)
    board[:pieces].first[:square]
  end

  it "mutates the target entity and emits its own event, in ONE dispatch that never names the entity" do
    runtime = boot
    runtime.dispatch_flat("DelegatesTo::Board.OpenBoard", name: { value: "b1" })
    runtime.dispatch_flat("DelegatesTo::Board.PlacePiece", name: "b1", id: { value: "p1" }, square: { file: 3, rank: 3 })

    result = runtime.dispatch("DelegatesTo::Board.MovePiece", to: "b1", with: { id: { value: "p1" }, to: { file: 5, rank: 5 } })

    expect(result.events.map(&:name)).to eq(["PieceMoved"])
    expect(square(runtime, name: "b1").to_h).to eq(file: 5, rank: 5)
  end

  # `with:` only remaps what it names, so `target_args` must start from the delegating
  # command's resolved args; otherwise a policy re-locating Board by `name` finds nothing.
  it "carries the delegating command's own ambient args through to the target's own emitted event" do
    runtime = boot
    runtime.dispatch_flat("DelegatesTo::Board.OpenBoard", name: { value: "b4" })
    runtime.dispatch_flat("DelegatesTo::Board.PlacePiece", name: "b4", id: { value: "p1" }, square: { file: 3, rank: 3 })

    runtime.dispatch("DelegatesTo::Board.MovePiece", to: "b4", with: { id: { value: "p1" }, to: { file: 5, rank: 5 } })

    board = runtime.registry.repository("DelegatesTo", runtime.registry.bluebook("DelegatesTo").aggregate("Board"))
                   .find("b4")
    expect(board[:move_count].to_h).to eq(value: 1)
  end

  it "raises the target's own refusal AS the delegating command's own refusal — synchronously, not recorded and swallowed" do
    runtime = boot
    runtime.dispatch_flat("DelegatesTo::Board.OpenBoard", name: { value: "b2" })
    runtime.dispatch_flat("DelegatesTo::Board.PlacePiece", name: "b2", id: { value: "p1" }, square: { file: 3, rank: 3 })

    expect do
      runtime.dispatch("DelegatesTo::Board.MovePiece", to: "b2", with: { id: { value: "p1" }, to: { file: 3, rank: 3 } })
    end.to raise_error(Hecks::Runtime::GivenNotMet, /destination differs from current square/)
  end

  it "persists nothing from a refused delegation — the failed attempt leaves the piece exactly where it was" do
    runtime = boot
    runtime.dispatch_flat("DelegatesTo::Board.OpenBoard", name: { value: "b3" })
    runtime.dispatch_flat("DelegatesTo::Board.PlacePiece", name: "b3", id: { value: "p1" }, square: { file: 3, rank: 3 })

    begin
      runtime.dispatch("DelegatesTo::Board.MovePiece", to: "b3", with: { id: { value: "p1" }, to: { file: 3, rank: 3 } })
    rescue Hecks::Runtime::GivenNotMet
      nil
    end

    expect(square(runtime, name: "b3").to_h).to eq(file: 3, rank: 3)
  end
end
