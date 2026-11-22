# frozen_string_literal: true

require "fileutils"
require "json"

module Hecks
  module Adapters
    class Guarding
      module Loop
        # The loops each pinned session re-creates on start. They are written where the SessionStart
        # hook reads them; the hook leaves a stamp per session, and the loop checks that the stamp
        # is newer than the resume, so a session that came back without its loops is seen.
        class Loops
          # @param home [String] the loop's directory
          # @param sessions [Array<Hash>] the roster's rows, each with its `loops`
          def initialize(home, sessions)
            @home = home
            @sessions = sessions
          end

          # @return [void]
          def write
            FileUtils.mkdir_p(@home)
            by_name = @sessions.to_h { |row| [row["name"], Array(row["loops"])] }
            File.write(File.join(@home, "loops.json"), JSON.pretty_generate(by_name))
          end

          # @param name [String] a pinned session
          # @param since [Integer] the moment it was resumed
          # @return [Boolean] whether its start hook has run since
          def armed?(name, since)
            stamp = File.join(@home, "armed", name)
            File.file?(stamp) && File.mtime(stamp).to_i >= since
          end
        end
      end
    end
  end
end
