# frozen_string_literal: true

require "open3"

module Hecks
  module Adapters
    class Guarding
      module Loop
        # What the loop runs on the machine: a command whose output it reads, or a command started
        # and left running on its own. It starts things and reads them; it signals nothing.
        class Shell
          Result = Struct.new(:out, :err, :ok) { alias_method :ok?, :ok }

          # @param argv [Array<String>] the command and its arguments
          # @param chdir [String, nil] the directory it runs from
          # @return [Result] its output, its error output and whether it succeeded
          def capture(*argv, chdir: nil)
            options = chdir ? { chdir: chdir } : {}
            out, err, status = Open3.capture3(*argv, **options)
            Result.new(out, err, status.success?)
          rescue SystemCallError => e
            Result.new("", e.message, false)
          end

          # Starts a command in a session of its own, so it outlives this loop, and does not wait.
          #
          # @param argv [Array<String>] the command and its arguments
          # @return [void]
          def detach(*argv, **)
            pid = Process.spawn(*argv, in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true)
            Process.detach(pid)
          rescue SystemCallError
            nil
          end
        end
      end
    end
  end
end
