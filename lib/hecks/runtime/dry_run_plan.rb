# frozen_string_literal: true

module Hecks
  module Runtime
    # What an in-memory dispatch would have written and announced, collected while the dispatch
    # runs. The command interpreter reports each save and each emitted event here when it runs
    # in dry mode, so every command gets a plan from the same seam with no per-command code.
    module DryRunPlan
      KEY = :hecks_dry_run_plan

      module_function

      # Runs the block and returns the lines it would have produced.
      #
      # @yield the in-memory dispatch
      # @return [Array<String>] one `would …` line per write or event, in order
      def collect
        previous = Thread.current[KEY]
        Thread.current[KEY] = []
        yield
        Thread.current[KEY]
      ensure
        Thread.current[KEY] = previous
      end

      # Records one write the dispatch would make.
      #
      # @param aggregate [Bluebook::Aggregate] the aggregate the record belongs to
      # @param instance [Runtime::Instance] the record the dispatch would write
      # @return [void]
      def write(aggregate, instance)
        record("would write #{aggregate.hecks_name} #{instance.id}")
      end

      # Records one event the dispatch would announce.
      #
      # @param name [String] the event's name
      # @return [void]
      def emit(name)
        record("would emit #{name}")
      end

      # Records each event a command announces.
      #
      # @param command [Bluebook::Command] the command the dispatch runs
      # @return [void]
      def emits(command)
        command.emits.each { |name| emit(name) }
      end

      # Appends a line when a plan is being collected; otherwise does nothing.
      #
      # @param line [String]
      # @return [void]
      def record(line)
        Thread.current[KEY]&.push(line)
      end
    end
  end
end
