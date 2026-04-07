# Hecks::Command::Validation
# Pre/postcondition DSL and enforcement for command objects.
# Included automatically via Hecks::Command.
#
# Usage:
#   class CreatePost
#     include Hecks::Command
#     precondition("title required") { |cmd| cmd.title.present? }
#   end

module Hecks
  module Command
    # Hecks::Command::Validation
    #
    # Pre/postcondition DSL and enforcement for command objects, included automatically via Hecks::Command.
    #
    module Validation
      def self.included(base)
        base.extend(Validation::ClassMethods)
      end

      # Class-level DSL for registering pre/postconditions.
      module ClassMethods
        # Returns the list of registered precondition checks.
        # Preconditions are validated before the command's +#call+ executes.
        #
        # @return [Array<DomainModel::Behavior::Condition>] registered preconditions
        def preconditions
          @preconditions ||= []
        end

        # Returns the list of registered postcondition checks.
        # Postconditions are validated after +#call+ returns, receiving the
        # before and after states of the aggregate.
        #
        # @return [Array<DomainModel::Behavior::Condition>] registered postconditions
        def postconditions
          @postconditions ||= []
        end

        # Registers a precondition that must hold before the command executes.
        # The block is evaluated in the context of the command instance via
        # +instance_exec+, so it has access to command attributes.
        #
        # @param message [String] human-readable description of the precondition
        # @yield block that returns truthy if the precondition holds
        # @return [void]
        # @raise [Hecks::PreconditionError] at execution time if the block returns falsey
        def precondition(message, &block)
          preconditions << DomainModel::Behavior::Condition.new(message: message, block: block)
        end

        # Registers a postcondition that must hold after the command executes.
        # The block receives the aggregate state before and after +#call+.
        #
        # @param message [String] human-readable description of the postcondition
        # @yield [before, after] block that returns truthy if the postcondition holds
        # @yieldparam before [Object, nil] the aggregate before execution (nil for creates)
        # @yieldparam after [Object] the aggregate after execution
        # @return [void]
        # @raise [Hecks::PostconditionError] at execution time if the block returns falsey
        def postcondition(message, &block)
          postconditions << DomainModel::Behavior::Condition.new(message: message, block: block)
        end
      end

      private

      # Evaluates all registered preconditions in the command instance context.
      # Raises +Hecks::PreconditionError+ on the first failure.
      #
      # @return [void]
      # @raise [Hecks::PreconditionError] if any precondition block returns falsey
      def check_preconditions
        self.class.preconditions.each do |cond|
          unless instance_exec(&cond.block)
            raise Hecks::PreconditionError, "Precondition failed: #{cond.message}"
          end
        end
      end

      # Evaluates all registered postconditions, comparing the aggregate state
      # before and after command execution.
      #
      # @param before [Object, nil] the aggregate state before execution
      # @param after [Object] the aggregate state after execution
      # @return [void]
      # @raise [Hecks::PostconditionError] if any postcondition block returns falsey
      def check_postconditions(before, after)
        self.class.postconditions.each do |cond|
          unless cond.block.call(before, after)
            raise Hecks::PostconditionError, "Postcondition failed: #{cond.message}"
          end
        end
      end

      # Attempts to find the existing aggregate for before/after postcondition
      # comparison. Looks for an instance variable ending in +_id+ and uses it
      # to fetch from the repository.
      #
      # @return [Object, nil] the existing aggregate, or nil if not found or no postconditions
      def find_existing_for_postcondition
        return nil if self.class.postconditions.empty?
        id_method = instance_variables.find { |v| v.to_s.end_with?("_id") }
        return nil unless id_method
        id_val = instance_variable_get(id_method)
        repository&.find(id_val) rescue nil
      end
    end
  end
end
