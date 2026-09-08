require "spec_helper"
require "tempfile"

# Real coverage for issue #138: `then_set :list, append: :bare_symbol` (a
# scalar, not the usual `append: { field: :value, ... }` Hash) crashed —
# `Mutation#appended_fields`/`MutationApplier#appended`/the meta-validator
# Judge's own `mutation_rows` all call `Hash#transform_values` on
# `mutation.source` unconditionally, and a bare Symbol has no such method.
# Confirmed genuinely crashing before this fix (`git stash`): a plain
# `NoMethodError: undefined method 'transform_values' for :tag:Symbol`,
# raised from `Mutation#appended_fields` the moment the bluebook's own IR
# was built (`BluebookBuilder#build` -> `MetaValidator.call` -> `Command#to_h`
# -> `Mutation#to_h`) — before any dispatch ever ran, and regardless of
# whether meta-validation is on or off.
#
# `CommandBuilder#normalize_append_source` treats the bare value the same
# way an explicit `append: { value: :bare_symbol }` already would — the
# `:value` name mirrors `MutationApplier#appended`'s own single-field
# value-object scalar-unwrap convention. This spec boots with
# meta-validation ON (no ENV override) so both the runtime dispatch path
# AND the meta-validator's own Judge path (`Readings#mutation_rows`) are
# exercised for real, not just one of the two.
RSpec.describe "mutation op append, bare-symbol shorthand" do
  def boot(source, hecksagon_name, &binds)
    file = Tempfile.new(["mutation-append-bare-symbol-growth-", ".bluebook"])
    file.write(source)
    file.flush

    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)
      Hecks.hecksagon(hecksagon_name, &binds)
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(
      Hecks::Runtime::Dispatcher.new(registry)
    )
  ensure
    file&.close!
  end

  MUTATION_APPEND_BARE_SYMBOL_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "MutationAppendBareSymbolGrowth" do
      aggregate "Widget" do
        identified_by :id

        value_object "WidgetId" do
          attribute :value, String
        end

        value_object "Tag" do
          attribute :value, String
        end

        attribute :id,   WidgetId
        attribute :tags, list_of(Tag)

        command "Open" do
          attribute :id, WidgetId
          emits "WidgetOpened"
        end

        # THE SHAPE UNDER TEST — a bare Symbol, not a Hash.
        command "Tag" do
          reference_to Widget
          attribute :tag, String

          sets :tags, append: :tag
          emits "WidgetTagged"
        end
      end
    end
  BLUEBOOK

  def widget_repository(runtime)
    aggregate = runtime.registry.bluebook("MutationAppendBareSymbolGrowth").aggregate("Widget")
    runtime.registry.repository("MutationAppendBareSymbolGrowth", aggregate)
  end

  def boot_mutation_append_bare_symbol
    boot(MUTATION_APPEND_BARE_SYMBOL_SOURCE, "MutationAppendBareSymbolGrowth") do
      MutationAppendBareSymbolGrowth::Widget.persisted_by("Memory")
    end
  end

  it "builds without raising, meta-validation on" do
    expect { boot_mutation_append_bare_symbol }.not_to raise_error
  end

  it "appends the bare value as the sole :value field of the list element" do
    runtime = boot_mutation_append_bare_symbol
    runtime.dispatch("MutationAppendBareSymbolGrowth::Widget.Open", id: { value: "w1" })
    runtime.dispatch("MutationAppendBareSymbolGrowth::Widget.Tag", id: "w1", tag: "fragile")

    widget = widget_repository(runtime).find("w1")
    expect(widget[:tags].map { |t| t[:value] }).to eq(["fragile"])
  end

  it "appends a second element independently, position preserved" do
    runtime = boot_mutation_append_bare_symbol
    runtime.dispatch("MutationAppendBareSymbolGrowth::Widget.Open", id: { value: "w2" })
    runtime.dispatch("MutationAppendBareSymbolGrowth::Widget.Tag", id: "w2", tag: "fragile")
    runtime.dispatch("MutationAppendBareSymbolGrowth::Widget.Tag", id: "w2", tag: "urgent")

    widget = widget_repository(runtime).find("w2")
    expect(widget[:tags].map { |t| t[:value] }).to eq(["fragile", "urgent"])
  end

  it "an explicit Hash append: is untouched by the normalization" do
    aggregate = Hecks::Bluebook::DSL::BluebookBuilder.build("HashAppendUnaffected") do
      aggregate "Sprint" do
        identified_by :id
        value_object("SprintId") { attribute :value, String }
        value_object("Dependency") { attribute :value, String }
        attribute :id,           SprintId
        attribute :dependencies, list_of(Dependency)

        command "AddDependency" do
          reference_to Sprint
          attribute :dependency, Dependency
          sets :dependencies, append: { value: :dependency }
        end
      end
    end.aggregates.first

    mutation = aggregate.commands.first.mutations.first
    expect(mutation.source).to eq(value: :dependency)
  end
end
