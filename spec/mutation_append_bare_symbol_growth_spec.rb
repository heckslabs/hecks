require "spec_helper"
require_relative "support/inline_bluebook_boot"

# `then_set :list, append: :bare_symbol` (a scalar, not a Hash) must not crash `transform_values`.
# Boots with meta-validation on so both the runtime and the Judge path are exercised.
RSpec.describe "mutation op append, bare-symbol shorthand" do
  include InlineBluebookBoot

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
    boot(MUTATION_APPEND_BARE_SYMBOL_SOURCE, "MutationAppendBareSymbolGrowth", validate: true) do
      MutationAppendBareSymbolGrowth::Widget.persisted_by("Memory")
    end
  end

  # A booted runtime holding one opened widget.
  def boot_with_widget(id)
    runtime = boot_mutation_append_bare_symbol
    runtime.dispatch_flat("MutationAppendBareSymbolGrowth::Widget.Open", id: { value: id })
    runtime
  end

  def tag_widget(runtime, id, tag)
    runtime.dispatch_flat("MutationAppendBareSymbolGrowth::Widget.Tag", id: id, tag: tag)
  end

  def tags_of(runtime, id) = widget_repository(runtime).find(id)[:tags].map { |t| t[:value] }

  it "builds without raising, meta-validation on" do
    expect { boot_mutation_append_bare_symbol }.not_to raise_error
  end

  it "appends the bare value as the sole :value field of the list element" do
    runtime = boot_with_widget("w1")
    tag_widget(runtime, "w1", "fragile")

    expect(tags_of(runtime, "w1")).to eq(["fragile"])
  end

  it "appends a second element independently, position preserved" do
    runtime = boot_with_widget("w2")
    %w[fragile urgent].each { |tag| tag_widget(runtime, "w2", tag) }

    expect(tags_of(runtime, "w2")).to eq(["fragile", "urgent"])
  end

  HASH_APPEND_CHAPTER = proc do
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
  end

  it "an explicit Hash append: is untouched by the normalization" do
    chapter = Hecks::Bluebook::DSL::BluebookBuilder.build("HashAppendUnaffected", &HASH_APPEND_CHAPTER)
    mutation = chapter.aggregates.first.commands.first.mutations.first

    expect(mutation.source).to eq(value: :dependency)
  end
end
