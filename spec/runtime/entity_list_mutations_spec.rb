require "spec_helper"

# Covers EntityInterpreter#apply_to_element's :append/:remove/:multiply/:clamp cases (ADR 0026).
RSpec.describe "an entity's own list-typed attribute" do
  # Not `FIXTURE`: a bare constant in a describe block lands on `Object`, so another spec's
  # same-named constant would silently win in the full suite.
  ENTITY_LIST_MUTATIONS_FIXTURE = File.join(InMemoryDomain::ROOT,
                                            "spec/fixtures/entity_list_mutations/entity_list_mutations.bluebook")

  def boot
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(ENTITY_LIST_MUTATIONS_FIXTURE)
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  def open_list(runtime, board:, label:)
    runtime.dispatch_flat("EntityListMutations::Board.OpenBoard", name: { value: board })
    runtime.dispatch_flat("EntityListMutations::Board.AddList", name: board, label: { value: label })
  end

  def board_with_list(board)
    runtime = boot
    open_list(runtime, board: board, label: "todo")
    runtime
  end

  def stored_board(runtime, name)
    board = runtime.registry.bluebook("EntityListMutations").aggregate("Board")
    runtime.registry.repository("EntityListMutations", board).find(name)
  end

  def first_list(runtime, name) = stored_board(runtime, name)[:lists].first

  def tag_pairs(tags) = tags.map { |t| [t[:key], t[:value]] }

  def tagged_list(runtime, verb, board, **args)
    command = "EntityListMutations::Board.TaggedList.#{verb}"
    runtime.dispatch_flat(command, name: { value: board }, label: { value: "todo" }, **args)
  end

  def add_tag(runtime, board, key, value) = tagged_list(runtime, "AddTag", board, key: key, value: value)

  def set_tags(runtime, board)
    runtime.dispatch_flat("EntityListMutations::Board.OpenBoard", name: { value: board })
    runtime.dispatch_flat("EntityListMutations::Board.SetTags", name: board,
                                                                tags: [{ key: "a", value: "1" }, { key: "b", value: "2" }])
  end

  # A board whose list entity was bumped twice (count 2) then scaled by ten.
  def scaled_board(board)
    runtime = board_with_list(board)
    2.times { tagged_list(runtime, "Bump", board) }
    tagged_list(runtime, "Scale", board, factor: 10)
    runtime
  end

  it "appends a value-object element onto the entity's own list" do
    runtime = board_with_list("b1")
    add_tag(runtime, "b1", "priority", "high")

    expect(tag_pairs(first_list(runtime, "b1")[:tags])).to eq([["priority", "high"]])
  end

  it "appends a second element without disturbing the first" do
    runtime = board_with_list("b2")
    add_tag(runtime, "b2", "a", "1")
    add_tag(runtime, "b2", "b", "2")

    expect(tag_pairs(first_list(runtime, "b2")[:tags])).to eq([["a", "1"], ["b", "2"]])
  end

  it "removes an element from the entity's own list by value equality" do
    runtime = board_with_list("b3")
    add_tag(runtime, "b3", "a", "1")
    add_tag(runtime, "b3", "b", "2")

    tagged_list(runtime, "RemoveTag", "b3", tag: { key: "a", value: "1" })

    expect(tag_pairs(first_list(runtime, "b3")[:tags])).to eq([["b", "2"]])
  end

  it "increments and multiplies a scalar field owned by the entity itself" do
    runtime = scaled_board("b4")

    expect(first_list(runtime, "b4")[:count][:value]).to eq(20)
  end

  it "clamps a scalar field owned by the entity itself" do
    runtime = scaled_board("b4")
    tagged_list(runtime, "Clamp", "b4")

    expect(first_list(runtime, "b4")[:count][:value]).to eq(10)
  end

  # ADR 0047: a bare `sets :field` whole-array argument must hydrate a value-object list into
  # real `Value`s, not leave plain Hashes that skip the value object's checks.
  it "hydrates a bare-sets-populated value-object list into real Values, not raw Hashes", :aggregate_failures do
    runtime = boot
    set_tags(runtime, "b5")

    tags = stored_board(runtime, "b5")[:tags]
    expect(tags).to all(be_a(Hecks::Runtime::Value))
    expect(tag_pairs(tags)).to eq([["a", "1"], ["b", "2"]])
  end

  it "removes an element from a bare-sets-populated value-object list by value equality" do
    runtime = boot
    set_tags(runtime, "b6")

    runtime.dispatch_flat("EntityListMutations::Board.RemoveTagFromBoard", name: "b6", tag: { key: "a", value: "1" })

    expect(tag_pairs(stored_board(runtime, "b6")[:tags])).to eq([["b", "2"]])
  end
end
