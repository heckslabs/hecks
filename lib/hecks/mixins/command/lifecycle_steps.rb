# Hecks::Command::LifecycleSteps
#
# Each step in the command lifecycle as a callable object.
# Steps follow a consistent interface: call(cmd) returns cmd.
# The pipeline executes them in order.
#
#   LIFECYCLE = [GuardStep, HandlerStep, PreconditionStep, ValidateReferencesStep, ...]
#
module Hecks
  module Command
    module LifecycleSteps
      GuardStep = ->(cmd) {
        cmd.send(:run_guard)
        cmd
      }

      HandlerStep = ->(cmd) {
        cmd.send(:run_handler)
        cmd
      }

      PreconditionStep = ->(cmd) {
        cmd.send(:check_preconditions)
        cmd
      }

      ValidateReferencesStep = ->(cmd) {
        cmd.send(:validate_references)
        cmd
      }

      CallStep = ->(cmd) {
        result = if cmd.class.command_bus && !cmd.class.command_bus.middleware.empty?
          cmd.class.command_bus.dispatch_with_command(cmd) { cmd.call }
        else
          cmd.call
        end
        cmd.instance_variable_set(:@aggregate, result)
        cmd
      }

      PostconditionStep = ->(cmd) {
        before = cmd.send(:find_existing_for_postcondition)
        cmd.send(:check_postconditions, before, cmd.aggregate)
        cmd
      }

      PersistStep = ->(cmd) {
        cmd.send(:persist_aggregate)
        cmd
      }

      EmitStep = ->(cmd) {
        cmd.send(:emit_event)
        cmd
      }

      RecordStep = ->(cmd) {
        cmd.send(:record_event_for_aggregate)
        cmd
      }

      PIPELINE = [
        GuardStep, HandlerStep, PreconditionStep, ValidateReferencesStep, CallStep,
        PostconditionStep, PersistStep, EmitStep, RecordStep
      ].freeze

      DRY_RUN_PIPELINE = [
        GuardStep, HandlerStep, PreconditionStep, ValidateReferencesStep, CallStep,
        PostconditionStep
      ].freeze
    end
  end
end
