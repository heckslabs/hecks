require_relative "../projector"

module Hecks
  module Projections
    # The command that undoes a declared command, read from the bluebook's compensations: a
    # process manager's dispatch that names a `compensates` for the command. Answers "none
    # declared" when no compensation is declared, and never invents one.
    #
    #   Projector.call(:undo, bluebook: bluebook, options: { command: "Account.Debit" })
    module Undo
      extend Hecks::Projector::Target

      projects_as :undo

      module_function

      # @param bluebook [Bluebook::Declaration] the bluebook holding the process managers
      # @param options [Hash{Symbol => Object}] `command:`, the command's verb form, e.g.
      #   "Account.Debit"
      # @return [Array<String>] one sentence: the undoing command, or that none is declared
      def call(bluebook:, options: {})
        command = options.fetch(:command)
        compensation = compensation_for(bluebook, command)
        return ["#{command} has no undo declared: its bluebook names no compensating command."] unless compensation

        ["#{command} is undone by #{compensation}, a compensation the bluebook declares."]
      end

      # The name of the command that undoes the named one, or nil.
      #
      # @return [String, nil]
      def compensation_for(bluebook, command)
        dispatch = bluebook.process_managers
                           .flat_map { |manager| manager.handlers.flat_map(&:dispatches) }
                           .find { |candidate| same_command?(candidate.command_name, command) && candidate.compensates }
        compensation = dispatch&.compensates
        compensation&.command_name
      end

      # Whether two command names are the same command, in either the `::` or the `.` spelling.
      def same_command?(left, right)
        normal = ->(name) { name.to_s.gsub("::", ".") }
        normal.call(left) == normal.call(right)
      end
    end
  end
end
