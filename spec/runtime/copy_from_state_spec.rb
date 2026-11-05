require "spec_helper"

# `state(:field)` as a mutation source. What it does to `last_ply`/`ply` and the `given` over the
# snapshots are in examples/copy_from_state/bluebook/copy_from_state.behaviors. What stays here is
# what `expect` cannot say: the shape of the appended snapshot list (a list of structured values),
# that it is a copy by value, and how the source appears in the IR.
RSpec.describe "a mutation sourced from the record's own state" do
  let(:runtime) do
    path = File.join(InMemoryDomain::ROOT, "examples/copy_from_state/bluebook/copy_from_state.bluebook")
    Hecks.boot_files([path], install_driving: false).tap do |bound|
      bound.dispatch_flat("Snapshots::Board.Create", label: { value: "b" })
      bound.dispatch("Snapshots::Board.Place", to: "b", with: { id: "p1", square: { file: 1 } })
    end
  end

  def board_of(result) = Hecks::Runtime::Value.materialize(result.state.to_h)

  it "copies the record's own fields into the appended element" do
    board = board_of(runtime.dispatch("Snapshots::Board.Record", to: "b", with: {}))

    expect(board[:positions]).to eq([{ ply: { value: 0 }, pieces: [{ id: { value: "p1" }, square: { file: 1 } }] }])
  end

  it "snapshots by value — a later move does not rewrite an earlier position", :aggregate_failures do
    runtime.dispatch("Snapshots::Board.Record", to: "b", with: {})
    board = board_of(runtime.dispatch("Snapshots::Board.MovePiece", to: "b", with: { id: "p1", to: { file: 2 } }))

    expect(board[:positions].first[:pieces]).to eq([{ id: { value: "p1" }, square: { file: 1 } }])
    expect(board[:pieces]).to eq([{ id: { value: "p1" }, square: { file: 2 } }])
  end

  it "carries the source through the IR as its own kind", :aggregate_failures do
    command = runtime.registry.bluebook("Snapshots").aggregate("Board").command("Record")
    mutations = command.mutations.map(&:to_h)
    expect(mutations[0][:fields]).to eq(ply: "state(:ply)", pieces: "state(:pieces)")
    expect(mutations[1][:source]).to eq(kind: "state", name: "ply")
  end
end
