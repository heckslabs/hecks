# frozen_string_literal: true

require "open3"
require_relative "../../../text"

module Hecks
  module QualityControlCli
    class QaLogBug
      # The proof `bug.log` demands before it writes anything: the demonstration must fail when run,
      # or, with `--reproduced no`, must at least look like runnable code.
      module Proof
        # A command word that starts runnable code: a script path, an interpreter or a shell.
        RUNNABLE_COMMAND = %r{\A(bundle|bin/|\./|rspec|ruby|sh|bash|zsh|python3?|node|cargo)\b}

        # A source file name: Ruby, shell, Python, Rust or JavaScript.
        SOURCE_FILE = /\.(rb|sh|py|rs|js)\b/

        private

        # Only used with `--reproduced no`, which never runs the string: a file path, an interpreter
        # or shell invocation, or a `Hecks::Fuzzing::Replay` snippet counts as code; prose does not.
        def looks_runnable?(str)
          first = first_word(str)
          return true if first.start_with?("/") && File.exist?(first)
          return true if File.exist?(File.expand_path(first, @root))
          return true if first.match?(RUNNABLE_COMMAND)
          return true if str.match?(SOURCE_FILE)
          return true if str.include?("Hecks::Fuzzing::Replay")

          false
        end

        # The first whitespace-separated word of `str`, or `""` for none.
        def first_word(str)
          words = str.to_s.strip.split(Text::WHITESPACE)
          words.first.to_s
        end

        # Runs through `sh -c` from the repository root; the output tail prints either way.
        def prove(options)
          return skip_proof(options[:demonstration]) if options[:reproduced] == "no"

          run_demonstration(options[:demonstration])
        end

        def skip_proof(demonstration)
          refuse_unrunnable!(demonstration) unless looks_runnable?(demonstration)
          puts "reproduced=no — skipping the must-fail check (no reliable pass/fail signal for this finding)"
          puts "demonstration (best-effort, not run): #{demonstration}"
        end

        def refuse_unrunnable!(demonstration)
          abort "#{USAGE}\nrefused: --demonstration doesn't look like a runnable script or command — " \
                "#{demonstration.inspect}\n" \
                "with --reproduced no there is no pass/fail signal to check, but the demonstration must " \
                "still be real, saved, runnable code (a file path or a shell/ruby invocation), never " \
                "prose describing what happened. Nothing was logged."
        end

        def run_demonstration(demonstration)
          out, status = Open3.capture2e("sh", "-c", demonstration, chdir: @root)
          tail = out.lines.last(15).join
          refuse_passing!(demonstration, tail) if status.success?

          puts "demonstration failed as required (exit #{status.exitstatus.inspect}):"
          puts tail
        end

        def refuse_passing!(demonstration, tail)
          puts tail
          abort "refused: the demonstration PASSED (exit 0) — #{demonstration.inspect}\n" \
                "a bug is logged with the failing test that proves it; a passing command proves nothing. " \
                "Nothing was logged."
        end
      end
    end
  end
end
