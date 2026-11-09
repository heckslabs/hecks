module Hecks
  module Adapters
    module Driving
      module Resident
        # Phase marks for one launcher line, printed to standard error when `HECKS_TRACE_TIMING` is
        # set and nothing otherwise. Each mark is the wall clock in milliseconds, so the marks of
        # the launcher and of the resident's child, which are different processes, share one
        # timeline:
        #
        #     launcher_start, child_took_over, script_load_begin, usage_begin/_end,
        #     boot_begin/_end, call_begin/_end, child_exit
        #
        # The time from the shell to `launcher_start` is the interpreter's own start.
        module Trace
          module_function

          # @return [Boolean] whether this line asked for marks
          def on? = ENV.key?("HECKS_TRACE_TIMING")

          # @return [Float] the wall clock in milliseconds
          def wall_ms = Process.clock_gettime(Process::CLOCK_REALTIME) * 1000

          # Prints one mark.
          #
          # @param name [String] the phase that has just been reached
          # @return [void]
          def mark(name)
            warn("TRACE #{name} #{wall_ms.round(1)}") if on?
          end

          # Marks the launcher's own start, from the monotonic reading the launcher took first.
          #
          # @param began [Float] `HECKS_LAUNCHED_AT`
          # @return [void]
          def launched(began)
            return unless on?

            ago = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - began) * 1000
            warn("TRACE launcher_start #{(wall_ms - ago).round(1)}")
          end

          # Wraps the calls a line makes after the fork, so the child's work shows by phase.
          module Calls
            def describe(*, **)
              Trace.mark("describe_begin")
              super.tap { Trace.mark("describe_end") }
            end

            def boot_described(*, **)
              Trace.mark("boot_begin")
              super.tap { Trace.mark("boot_end") }
            end
          end

          # Wraps the runner's two entry points the same way.
          module Runner
            def usage(*, **)
              Trace.mark("usage_begin")
              super.tap { Trace.mark("usage_end") }
            end

            def call(*, **)
              Trace.mark("call_begin")
              super.tap { Trace.mark("call_end") }
            end
          end

          # Installs the wrappers in a child that asked for marks.
          #
          # @return [void]
          def install
            return unless on?

            Hecks.singleton_class.prepend(Calls)
            Hecks::Adapters::Driving::CliRunner.singleton_class.prepend(Runner)
          end
        end
      end
    end
  end
end
