require "spec_helper"
require "tempfile"

# A VO-typed lifecycle field must unwrap to its inner scalar when matching `from`.
# It only shows on the second transition: the field starts as a raw default and
# becomes a Value once the first transition wraps it.
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

        # THE TRANSITIONS MOVE `status` (C5.3) — a `sets` on the lifecycle
        # field is refused at build.
        command "Advance" do
          reference_to Task
          emits "TaskAdvanced"
        end

        command "Finish" do
          reference_to Task
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
    runtime.dispatch_flat("LifecycleValueScalarGrowth::Task.Open", id: { value: "t1" })
    runtime.dispatch_flat("LifecycleValueScalarGrowth::Task.Advance", id: "t1")

    expect { runtime.dispatch_flat("LifecycleValueScalarGrowth::Task.Finish", id: "t1") }.not_to raise_error

    task = repository_for(runtime).find("t1")
    expect(task[:status][:value]).to eq("done")
  end

  it "still refuses a transition from a state the field never held" do
    runtime = boot_lifecycle_value_scalar
    runtime.dispatch_flat("LifecycleValueScalarGrowth::Task.Open", id: { value: "t2" })

    expect { runtime.dispatch_flat("LifecycleValueScalarGrowth::Task.Finish", id: "t2") }
      .to raise_error(Hecks::Runtime::LifecycleRefused)
  end
end
