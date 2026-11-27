# frozen_string_literal: true

module Hecks
  module Adapters
    class MachineSampling
      # What a process is for, told from its whole command line: specs, gates and lint; Hecks boots
      # and beats; the file-event daemon; Claude sessions; or anything else.
      module Purposes
        SPECS = /rspec|rubocop|test_suite_run|gate_run|style_run|check_comments/
        FSEVENTSD = /\bfseventsd\b/
        HECKS = %r{exe/hecks|bin/hecks|/hecks\b|\bhecks\s}
        CLAUDE = /\bclaude\b/

        # @param command [String] a process's command line
        # @return [String] `specs_gates_lint`, `fseventsd`, `hecks_boots_beats`, `claude_sessions`
        #   or `other`
        def self.of(command)
          return "specs_gates_lint" if SPECS.match?(command)
          return "fseventsd" if FSEVENTSD.match?(command)
          return "hecks_boots_beats" if HECKS.match?(command)

          CLAUDE.match?(command) ? "claude_sessions" : "other"
        end
      end
    end
  end
end
