# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # Finds the session that still waits on a person behind a run that has ended, so a step whose
      # run ended can be sent to the session instead, or refused by name with the text kept.
      module EndedRun
        module_function

        # @param step [String, nil] the step the `ActionRule` row names for an ended run
        # @param sessions [Array<Hash>, nil] the board's sessions
        # @param run [String] the run key the page named
        # @return [Hash] the blocked session of that run, with a resume id
        # @raise [PipelineBoard::Unavailable] when the step has no fallback or no session waits
        def waiting(step, sessions, run)
          found = step && Array(sessions).find { |row| row[:run] == run && blocked?(row) }
          return found if found

          raise PipelineBoard::Unavailable,
                "run #{run} has ended and no session of it waits on a person, so it cannot be answered; " \
                "your answer is kept on the card"
        end

        # Runs the command a step names to run first (an answer checks the run), so the run holds
        # the job's own state before the step's rule is asked. Its refusal ends the step, except
        # the refusal of a run that has ended, which is the step's `ended` case.
        #
        # @param launcher [#call] the board's launcher
        # @param root [String] the directory it runs in
        # @param program [String] the program the check runs under
        # @param argv [Array<String>] the check's arguments
        # @return [Boolean] false when the run has ended
        # @raise [PipelineBoard::Unavailable] when the check is refused for any other reason
        def checked?(launcher, root, program, argv)
          launcher.call(program, *argv, chdir: root, stdin: nil)
          true
        rescue PipelineBoard::Unavailable => e
          return false if e.message.include?("lifecycle_refused")

          raise PipelineBoard::Unavailable, "the session could not be checked first: #{e.message}"
        end

        def blocked?(row) = row[:status] == "blocked" && !row[:attach].to_s.empty?
      end
    end
  end
end
