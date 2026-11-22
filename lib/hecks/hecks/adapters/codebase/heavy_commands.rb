# frozen_string_literal: true

require "hecks/rust_build/world_rows"

module Hecks
  module Adapters
    module Codebase
      # The commands the Tickets world declares heavy (its `heavy_commands` line), each with the job
      # class it takes a place as, so one admission path serves every such command and a command
      # not named, such as a wait on a remote run, takes none. Extended onto {HeavySlots}.
      module HeavyCommands
        # The verb of the Tickets world that names the commands that are heavy.
        VERB = "heavy_commands"

        # @param root [String] the hecks checkout whose world declares the heavy commands
        # @param verb [String] a command's verb, as the world's `heavy_commands` line spells it
        # @return [String, nil] the job class the command takes a place as, nil when not declared
        def job_of(root, verb) = RustBuild::WorldRows.row(root, VERB)[verb.to_sym]&.to_s

        # Runs a command in a place when the world declares it heavy, at once when not. The whole
        # command takes one place, however many files or calls it makes inside.
        #
        # @param root [String] the hecks checkout whose world declares the heavy commands
        # @param verb [String] the command's verb
        # @yieldreturn [Object] the command's answer
        # @return [Object] what the block returned
        def command(root, verb, &)
          job = job_of(root, verb)
          job ? held(root, job, &).first : yield
        end
      end
    end
  end
end
