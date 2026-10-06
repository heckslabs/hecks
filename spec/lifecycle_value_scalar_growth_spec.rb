require "spec_helper"
require_relative "support/inline_bluebook_boot"

# A VO-typed lifecycle field must unwrap to its inner scalar when matching `from`.
# It only shows on the second transition: the field starts as a raw default and
# becomes a Value once the first transition wraps it.
RSpec.describe "lifecycle transition on a VO-typed field" do
  include InlineBluebookBoot

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

  def open_task(runtime, id)
    runtime.dispatch_flat("LifecycleValueScalarGrowth::Task.Open", id: { value: id })
  end

  def task_command(runtime, command, id)
    runtime.dispatch_flat("LifecycleValueScalarGrowth::Task.#{command}", id: id)
  end

  it "admits a SECOND transition once the field is already Value-wrapped by the first", :aggregate_failures do
    runtime = boot_lifecycle_value_scalar
    open_task(runtime, "t1")
    task_command(runtime, "Advance", "t1")

    expect { task_command(runtime, "Finish", "t1") }.not_to raise_error
    expect(repository_for(runtime).find("t1")[:status][:value]).to eq("done")
  end

  it "still refuses a transition from a state the field never held" do
    runtime = boot_lifecycle_value_scalar
    open_task(runtime, "t2")

    expect { task_command(runtime, "Finish", "t2") }.to raise_error(Hecks::Runtime::LifecycleRefused)
  end
end
