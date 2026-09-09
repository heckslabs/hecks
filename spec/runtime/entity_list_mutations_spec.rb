require "spec_helper"

# S17, ADR 0026 — proves EntityInterpreter#apply_to_element's new
# :append/:remove/:multiply/:clamp cases (previously missing, and
# silently no-op'd rather than raised) against a dedicated fixture,
# before either mechanism is used to convert the meta-domain's own
# Member/Dispatch to real entities.
RSpec.describe "an entity's own list-typed attribute" do
  # NOT `FIXTURE` — a real, pre-existing gotcha this file's own first
  # draft rediscovered: `RSpec.describe "..." do ... end` is an
  # ORDINARY Ruby block, lexically scoped to wherever it was WRITTEN
  # (this file's own top level, i.e. `Object`) — so `FIXTURE = ...`
  # here does not become a constant on this describe block's own
  # anonymous class, it becomes the single process-wide
  # `Object::FIXTURE`. `spec/runtime/rebuild_sweep_spec.rb` already
  # names its own fixture path the same bare way; whichever spec file
  # RSpec happens to `require` LAST silently wins that constant for
  # the rest of the process, and every earlier spec sharing the name
  # loads whatever path won instead of its own — reproduced for real:
  # this file passed alone and failed only inside the full suite,
  # loading rebuild_sweep_spec's own fixture instead of its own.
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
      Hecks::Runtime::Loader.bind_runtime(
        Hecks::Runtime::Dispatcher.new(registry)
      )
    end
  end

  def open_list(runtime, board:, label:)
    runtime.dispatch("EntityListMutations::Board.OpenBoard", name: { value: board })
    runtime.dispatch("EntityListMutations::Board.AddList", name: board, label: { value: label })
  end

  it "appends a value-object element onto the entity's own list" do
    runtime = boot
    open_list(runtime, board: "b1", label: "todo")

    runtime.dispatch("EntityListMutations::Board.TaggedList.AddTag", name: { value: "b1" },
                     label: { value: "todo" }, key: "priority", value: "high")

    list = runtime.registry.repository("EntityListMutations", runtime.registry.bluebook("EntityListMutations").aggregate("Board"))
                  .find("b1")[:lists].first
    expect(list[:tags].map { |t| [t[:key], t[:value]] }).to eq([["priority", "high"]])
  end

  it "appends a second element without disturbing the first" do
    runtime = boot
    open_list(runtime, board: "b2", label: "todo")

    runtime.dispatch("EntityListMutations::Board.TaggedList.AddTag", name: { value: "b2" },
                     label: { value: "todo" }, key: "a", value: "1")
    runtime.dispatch("EntityListMutations::Board.TaggedList.AddTag", name: { value: "b2" },
                     label: { value: "todo" }, key: "b", value: "2")

    list = runtime.registry.repository("EntityListMutations", runtime.registry.bluebook("EntityListMutations").aggregate("Board"))
                  .find("b2")[:lists].first
    expect(list[:tags].map { |t| [t[:key], t[:value]] }).to eq([["a", "1"], ["b", "2"]])
  end

  it "removes an element from the entity's own list by value equality" do
    runtime = boot
    open_list(runtime, board: "b3", label: "todo")
    runtime.dispatch("EntityListMutations::Board.TaggedList.AddTag", name: { value: "b3" },
                     label: { value: "todo" }, key: "a", value: "1")
    runtime.dispatch("EntityListMutations::Board.TaggedList.AddTag", name: { value: "b3" },
                     label: { value: "todo" }, key: "b", value: "2")

    runtime.dispatch("EntityListMutations::Board.TaggedList.RemoveTag", name: { value: "b3" },
                     label: { value: "todo" }, tag: { key: "a", value: "1" })

    list = runtime.registry.repository("EntityListMutations", runtime.registry.bluebook("EntityListMutations").aggregate("Board"))
                  .find("b3")[:lists].first
    expect(list[:tags].map { |t| [t[:key], t[:value]] }).to eq([["b", "2"]])
  end

  it "increments, multiplies, and clamps a scalar field owned by the entity itself" do
    runtime = boot
    open_list(runtime, board: "b4", label: "todo")

    runtime.dispatch("EntityListMutations::Board.TaggedList.Bump", name: { value: "b4" }, label: { value: "todo" })
    runtime.dispatch("EntityListMutations::Board.TaggedList.Bump", name: { value: "b4" }, label: { value: "todo" })
    runtime.dispatch("EntityListMutations::Board.TaggedList.Scale", name: { value: "b4" }, label: { value: "todo" }, factor: 10)

    list = runtime.registry.repository("EntityListMutations", runtime.registry.bluebook("EntityListMutations").aggregate("Board"))
                  .find("b4")[:lists].first
    expect(list[:count][:value]).to eq(20)

    runtime.dispatch("EntityListMutations::Board.TaggedList.Clamp", name: { value: "b4" }, label: { value: "todo" })
    list = runtime.registry.repository("EntityListMutations", runtime.registry.bluebook("EntityListMutations").aggregate("Board"))
                  .find("b4")[:lists].first
    expect(list[:count][:value]).to eq(10)
  end

  # ADR 0047 — `Value::Coercion#hydrate_entity_list` used to bail out to a
  # raw, un-hydrated passthrough the moment its target attribute's type
  # named a value object rather than an entity, so a bare `sets :field`
  # (a whole-array argument, as opposed to element-by-element `append:`)
  # left the list holding plain Hashes forever — never real `Value`
  # instances, never through the value object's own `pattern:`/
  # `invariant` checks. `SetTags`/`RemoveTagFromBoard` exist on this
  # fixture's `Board` aggregate (not `TaggedList`, its entity — this is
  # the AGGREGATE-level path) purely to exercise that repro shape.
  it "hydrates a bare-sets-populated value-object list into real Values, not raw Hashes" do
    runtime = boot
    runtime.dispatch("EntityListMutations::Board.OpenBoard", name: { value: "b5" })
    runtime.dispatch("EntityListMutations::Board.SetTags", name: "b5",
                                                           tags: [{ key: "a", value: "1" }, { key: "b", value: "2" }])

    tags = runtime.registry.repository("EntityListMutations", runtime.registry.bluebook("EntityListMutations").aggregate("Board"))
                  .find("b5")[:tags]
    expect(tags).to all(be_a(Hecks::Runtime::Value))
    expect(tags.map { |t| [t[:key], t[:value]] }).to eq([["a", "1"], ["b", "2"]])
  end

  it "removes an element from a bare-sets-populated value-object list by value equality" do
    runtime = boot
    runtime.dispatch("EntityListMutations::Board.OpenBoard", name: { value: "b6" })
    runtime.dispatch("EntityListMutations::Board.SetTags", name: "b6",
                                                           tags: [{ key: "a", value: "1" }, { key: "b", value: "2" }])

    runtime.dispatch("EntityListMutations::Board.RemoveTagFromBoard", name: "b6", tag: { key: "a", value: "1" })

    tags = runtime.registry.repository("EntityListMutations", runtime.registry.bluebook("EntityListMutations").aggregate("Board"))
                  .find("b6")[:tags]
    expect(tags.map { |t| [t[:key], t[:value]] }).to eq([["b", "2"]])
  end
end
