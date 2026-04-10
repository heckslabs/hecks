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

      LifecycleGuardStep = ->(cmd) {
        # Enforce lifecycle state transitions if the aggregate has a lifecycle
        if cmd.class.respond_to?(:lifecycle_def) && cmd.class.lifecycle_def
          lc = cmd.class.lifecycle_def
          # Find the existing aggregate to check current state
          existing = cmd.respond_to?(:repository, true) && cmd.send(:repository).respond_to?(:all) ?
            cmd.send(:repository).all.last : nil
          if existing
            field = lc[:field]
            current = existing.respond_to?(field) ? existing.send(field) : nil
            if current
              transitions = lc[:transitions] || {}
              cmd_name = cmd.class.name.split("::").last
              transition = transitions[cmd_name]
              if transition && transition[:from] && !Array(transition[:from]).include?(current)
                raise Hecks::TransitionError.new(
                  command_name: cmd_name,
                  current_state: current,
                  required_from: Array(transition[:from]).join(" or ")
                )
              end
            end
          end
        end
        cmd
      }

      GivenStep = ->(cmd) {
        if cmd.class.respond_to?(:givens_ir) && cmd.class.givens_ir&.any?
          require "hecks/runtime/hecksal_interpreter"
          agg = cmd.respond_to?(:aggregate, true) ? cmd.send(:aggregate) : nil
          agg ||= cmd.respond_to?(:find_existing_for_postcondition, true) ? cmd.send(:find_existing_for_postcondition) : nil
          HecksalInterpreter.check_givens(agg || cmd, cmd, cmd.class.givens_ir) if agg || cmd
        end
        cmd
      }

      MutationStep = ->(cmd) {
        if cmd.class.respond_to?(:mutations_ir) && cmd.class.mutations_ir&.any?
          require "hecks/runtime/hecksal_interpreter"
          agg = cmd.instance_variable_get(:@aggregate)
          if agg
            HecksalInterpreter.apply_mutations(agg, cmd, cmd.class.mutations_ir)
          end
        end
        cmd
      }

      CallStep = ->(cmd) {
        result = if cmd.class.respond_to?(:mutations_ir) && cmd.class.mutations_ir&.any? && !cmd.class.respond_to?(:domain_handler)
          # Pure Bluebook command — update existing or create new aggregate
          if has_self_reference?(cmd)
            find_existing_aggregate(cmd) || build_aggregate_for(cmd)
          else
            build_aggregate_for(cmd)
          end
        elsif cmd.class.command_bus && !cmd.class.command_bus.middleware.empty?
          cmd.class.command_bus.dispatch_with_command(cmd) { cmd.call }
        else
          cmd.call
        end
        cmd.instance_variable_set(:@aggregate, result)
        cmd
      }

      # Does this command have a self-referencing reference_to?
      # Commands with reference_to Self are updates; without are creates.
      def self.has_self_reference?(cmd)
        return false unless cmd.class.respond_to?(:reference_meta) && cmd.class.reference_meta
        agg_name = cmd.class.name.split("::")[-3]
        cmd.class.reference_meta.any? { |ref|
          ref_name = ref.respond_to?(:name) ? ref.name : ref.to_s
          ref_name.to_s.downcase.tr("_", "") == agg_name.downcase
        }
      end

      # Find existing aggregate by ID from the command's reference attribute.
      def self.find_existing_aggregate(cmd)
        repo = cmd.respond_to?(:repository, true) ? cmd.send(:repository) : nil
        return nil unless repo
        # Look for a reference attribute matching the aggregate name
        agg_name = cmd.class.name.split("::")[-3]
        snake = agg_name.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                        .gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
        ref_id = cmd.respond_to?(snake.to_sym) ? cmd.send(snake.to_sym) : nil
        ref_id ? repo.find(ref_id) : repo.all.last
      end

      # Instantiate a fresh aggregate for create-style Bluebook commands.
      # Command lives at Domain::Aggregate::Commands::Name — aggregate is two levels up.
      def self.build_aggregate_for(cmd)
        parts = cmd.class.name.split("::")
        agg_class = Object.const_get(parts[0..-3].join("::"))
        attrs = {}
        if agg_class.respond_to?(:hecks_attributes)
          agg_class.hecks_attributes.each do |attr|
            key = attr[:name].to_sym
            attrs[key] = cmd.respond_to?(key) ? cmd.send(key) : nil
          end
        end
        agg_class.new(**attrs)
      end

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
        GuardStep, HandlerStep, PreconditionStep, GivenStep, ValidateReferencesStep,
        LifecycleGuardStep, CallStep, MutationStep,
        PostconditionStep, PersistStep, EmitStep, RecordStep
      ].freeze

      DRY_RUN_PIPELINE = [
        GuardStep, HandlerStep, PreconditionStep, GivenStep, ValidateReferencesStep,
        CallStep, MutationStep, PostconditionStep
      ].freeze
    end
  end
end
