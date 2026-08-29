require "spec_helper"
require "tempfile"

# Real dispatch coverage for the Value.scalar unwrap fix in the lifecycle-
# transition matcher: a VO-typed lifecycle field's bare `.to_s` used to hit
# Ruby's default Object#to_s instead of unwrapping the inner scalar, so
# `current` came back as a raw object-pointer string that could never match
# any declared `from` state. Bites on the SECOND transition specifically:
# the field starts as a raw, unwrapped default, and only becomes a real
# Value once the FIRST transition's `sets` wraps it -- a subsequent
# transition attempt is where the bug shows.
RSpec.describe "lifecycle transition on a VO-typed field" do
  def boot(source, hecksagon_name, &binds)
    file = Tempfile.new(["lifecycle-value-scalar-growth-", ".bluebook"])
    file.write(source)
    file.flush

    registry = Hecks::Runtime::Registry.new
    Hecks::Bluebook::MetaValidator.while_disabled do
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)
        Hecks.hecksagon(hecksagon_name, &binds)
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(
      Hecks::Runtime::Dispatcher.new(registry)
    )
  ensure
    file&.close!
  end

  LIFECYCLE_VALUE_SCALAR_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "LifecycleValueScalarGrowth" do
      aggregate "Task" do
        identified_by :id

        value_object "TaskId" do
          attribute :value, String
        end

        value_object "TaskStatus" do
          attribute :value, String
        end

        attribute :id,     TaskId
        attribute :status, TaskStatus

        command "Open" do
          attribute :id, TaskId
          emits "TaskOpened"
        end

        lifecycle :status, default: "open" do
          transition "Advance" => "closed", from: "open"
          transition "Finish"  => "done",   from: "closed"
        end

        command "Advance" do
          reference_to Task
          sets :status, to: "closed"
          emits "TaskAdvanced"
        end

        command "Finish" do
          reference_to Task
          sets :status, to: "done"
          emits "TaskFinished"
        end
      end
    end
  BLUEBOOK

  def repository_for(runtime)
    aggregate = runtime.registry.bluebook("LifecycleValueScalarGrowth").aggregate("Task")
    runtime.registry.repository("LifecycleValueScalarGrowth", aggregate)
  end

  def boot_lifecycle_value_scalar
    boot(LIFECYCLE_VALUE_SCALAR_SOURCE, "LifecycleValueScalarGrowth") do
      LifecycleValueScalarGrowth::Task.persisted_by("Memory")
    end
  end

  it "admits a SECOND transition once the field is already Value-wrapped by the first" do
    runtime = boot_lifecycle_value_scalar
    runtime.dispatch("LifecycleValueScalarGrowth::Task.Open", id: { value: "t1" })
    runtime.dispatch("LifecycleValueScalarGrowth::Task.Advance", id: "t1")

    expect { runtime.dispatch("LifecycleValueScalarGrowth::Task.Finish", id: "t1") }.not_to raise_error

    task = repository_for(runtime).find("t1")
    expect(task[:status][:value]).to eq("done")
  end

  it "still refuses a transition from a state the field never held" do
    runtime = boot_lifecycle_value_scalar
    runtime.dispatch("LifecycleValueScalarGrowth::Task.Open", id: { value: "t2" })

    expect { runtime.dispatch("LifecycleValueScalarGrowth::Task.Finish", id: "t2") }
      .to raise_error(Hecks::Runtime::LifecycleRefused)
  end
end
