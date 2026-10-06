require "spec_helper"
require_relative "support/inline_bluebook_boot"

# Real dispatch coverage for the `remove` mutation op: the list-removal
# counterpart to `append`, matching an element by value equality, no
# read-modify-write (plan.bluebook's RemoveDependency/DeactivateSprint --
# "a concurrent Add can never be lost").
RSpec.describe "mutation op remove" do
  include InlineBluebookBoot

  MUTATION_REMOVE_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "MutationRemoveGrowth" do
      aggregate "Sprint" do
        identified_by :id

        value_object "SprintId" do
          attribute :value, String
        end

        value_object "Dependency" do
          attribute :value, String
        end

        attribute :id,           SprintId
        attribute :dependencies, list_of(Dependency)

        command "Open" do
          attribute :id, SprintId
          emits "SprintOpened"
        end

        command "AddDependency" do
          reference_to Sprint
          attribute :dependency, Dependency

          sets :dependencies, append: { value: :dependency }
          emits "DependencyAdded"
        end

        command "RemoveDependency" do
          reference_to Sprint
          attribute :dependency, Dependency

          sets :dependencies, remove: :dependency
          emits "DependencyRemoved"
        end
      end
    end
  BLUEBOOK

  def sprint_repository(runtime)
    aggregate = runtime.registry.bluebook("MutationRemoveGrowth").aggregate("Sprint")
    runtime.registry.repository("MutationRemoveGrowth", aggregate)
  end

  def boot_mutation_remove
    boot(MUTATION_REMOVE_SOURCE, "MutationRemoveGrowth") do
      MutationRemoveGrowth::Sprint.persisted_by("Memory")
    end
  end

  def dispatch_sprint(runtime, command, **arguments)
    runtime.dispatch_flat("MutationRemoveGrowth::Sprint.#{command}", **arguments)
  end

  # Boots, opens sprint `id`, and adds each named dependency to it.
  def boot_sprint_with(id, *dependencies)
    runtime = boot_mutation_remove
    dispatch_sprint(runtime, "Open", id: { value: id })
    dependencies.each { |name| dispatch_sprint(runtime, "AddDependency", id: id, dependency: { value: name }) }
    runtime
  end

  def dependencies_of(runtime, id) = sprint_repository(runtime).find(id)[:dependencies].map { |d| d[:value] }

  it "removes a matching element by value equality" do
    runtime = boot_sprint_with("s1", "db", "api")
    dispatch_sprint(runtime, "RemoveDependency", id: "s1", dependency: { value: "db" })

    expect(dependencies_of(runtime, "s1")).to eq(["api"])
  end

  it "is a no-op, not an error, removing a value that was never added" do
    runtime = boot_sprint_with("s2", "db")
    dispatch_sprint(runtime, "RemoveDependency", id: "s2", dependency: { value: "nope" })

    expect(dependencies_of(runtime, "s2")).to eq(["db"])
  end
end
