require "spec_helper"
require "tempfile"

# Real dispatch coverage for the `remove` mutation op: the list-removal
# counterpart to `append`, matching an element by value equality, no
# read-modify-write (plan.bluebook's RemoveDependency/DeactivateSprint --
# "a concurrent Add can never be lost").
RSpec.describe "mutation op remove" do
  def boot(source, hecksagon_name, &binds)
    file = Tempfile.new(["mutation-remove-growth-", ".bluebook"])
    file.write(source)
    file.flush

    previous = ENV["HECKS_META_VALIDATION"]
    ENV["HECKS_META_VALIDATION"] = "off"

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
    ENV["HECKS_META_VALIDATION"] = previous
    file&.close!
  end

  MUTATION_REMOVE_SOURCE = <<~BLUEBOOK
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
      ::MutationRemoveGrowth::Sprint.persisted_by("Memory")
    end
  end

  it "removes a matching element by value equality" do
    runtime = boot_mutation_remove
    runtime.dispatch("MutationRemoveGrowth::Sprint.Open", id: { value: "s1" })
    runtime.dispatch("MutationRemoveGrowth::Sprint.AddDependency", id: "s1", dependency: { value: "db" })
    runtime.dispatch("MutationRemoveGrowth::Sprint.AddDependency", id: "s1", dependency: { value: "api" })

    runtime.dispatch("MutationRemoveGrowth::Sprint.RemoveDependency", id: "s1", dependency: { value: "db" })

    sprint = sprint_repository(runtime).find("s1")
    expect(sprint[:dependencies].map { |d| d[:value] }).to eq(["api"])
  end

  it "is a no-op, not an error, removing a value that was never added" do
    runtime = boot_mutation_remove
    runtime.dispatch("MutationRemoveGrowth::Sprint.Open", id: { value: "s2" })
    runtime.dispatch("MutationRemoveGrowth::Sprint.AddDependency", id: "s2", dependency: { value: "db" })

    runtime.dispatch("MutationRemoveGrowth::Sprint.RemoveDependency", id: "s2", dependency: { value: "nope" })

    sprint = sprint_repository(runtime).find("s2")
    expect(sprint[:dependencies].map { |d| d[:value] }).to eq(["db"])
  end
end
