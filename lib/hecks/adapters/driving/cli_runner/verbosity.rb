# frozen_string_literal: true

module Hecks
  module Adapters
    module Driving
      module CliRunner
        # The launcher's output levels. `-q` prints only the result and any refusal, so the progress
        # and the context line are left out. `-v` adds, on standard error, the command that ran, its
        # checkout and stores, and how long it took. The default prints what the launcher always
        # printed. The flags are taken from anywhere in the line, and cannot be given together.
        module Verbosity
          QUIET_FLAG = "-q"
          VERBOSE_FLAG = "-v"
          FLAGS = { QUIET_FLAG => :quiet, VERBOSE_FLAG => :verbose }.freeze
          CONFLICT = "hecks: -q and -v cannot be given together; give one of them, or neither"

          # Takes the level flags out of a line.
          #
          # @param argv [Array<String>] the words the launcher was given
          # @return [Array(Symbol, Array<String>)] the level (`:quiet`, `:verbose`, `:default`, or
          #   `:conflict` when both flags came) and the words without the flags
          def split_verbosity(argv)
            levels = argv.filter_map { |word| FLAGS[word] }.uniq
            return [:conflict, argv] if levels.length > 1

            [levels.first || :default, argv.reject { |word| FLAGS.key?(word) }]
          end

          # Runs a block at one level, and resets the level and the stage progress afterwards.
          #
          # @param level [Symbol] `:quiet`, `:verbose` or `:default`
          # @yield the answer the line gets at that level
          # @return [Object] the block's value
          def with_verbosity(level)
            require_relative "../../../tools/stage_progress"
            previous = Thread.current[:hecks_verbosity]
            Thread.current[:hecks_verbosity] = level
            Tools::StageProgress.quiet = level == :quiet
            yield
          ensure
            Thread.current[:hecks_verbosity] = previous
            Tools::StageProgress.quiet = previous == :quiet
          end

          # @return [Symbol] the level the line runs at
          def verbosity = Thread.current[:hecks_verbosity] || :default

          # @return [Boolean] whether only the result and any refusal are printed
          def quiet? = verbosity == :quiet

          # @return [Boolean] whether each step's details are printed on standard error
          def verbose? = verbosity == :verbose

          # The details `-v` adds after a command ran: the command, how long it took, and the
          # checkout and stores the line ran in.
          #
          # @param err [#puts] where the details go
          # @param name [String] the command or query that ran
          # @param started [Float] the monotonic clock reading when the line began
          # @return [void]
          def verbose_details(err, name, started)
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
            err.puts("command #{name}", format("took %.2fs", elapsed), checkout_line)
          end

          # @return [String] the context line, as `-v` prints it
          def checkout_line
            ContextLine.line(directory: Dir.pwd, stores: SettingsReading.new.stores(Dir.pwd),
                             audience: ContextLine.audience(Dir.pwd))
          end
        end
      end
    end
  end
end
