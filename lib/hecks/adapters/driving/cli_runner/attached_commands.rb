module Hecks
  module Adapters
    module Driving
      module CliRunner
        # Reads a line whose command the bluebook it was read against does not declare, against the
        # bluebooks the domain attaches. A domain that attaches a bluebook takes its aggregates as
        # its own vocabulary, so `Landing.land!` reaches the attached bluebook that declares
        # `Landing` without the caller writing which one (`delivery Landing.land!`). Extended into
        # `CliRunner`.
        module AttachedCommands
          # The plan of a line no command of the first bluebook answers, when exactly one attached
          # bluebook declares it. Two that both do leave the line unknown: the caller says which.
          #
          # @param runtime [#bluebook, #hecksagon, #first_bluebook] the domain
          # @param argv [Array<String>] the line, as it was read against the first bluebook
          # @param program [String] how the caller was invoked
          # @return [Hash, nil] the plan, read against the attached bluebook under the program
          #   name that reaches it (`hecks delivery`), or nil when none or several declare it
          def attached_plan(runtime, argv, program)
            plans = holders(runtime, argv).map do |bluebook|
              command_plan(scope_of(runtime, bluebook, "#{program} #{Naming.snake(bluebook.name)}"), argv)
            end
            found = plans.reject { |plan| plan[:unknown] }
            found.first if found.size == 1
          end

          # What a line is read against: a bluebook, its launcher settings and its projection.
          #
          # @return [Hash] `runtime`, `bluebook`, `launcher`, `options`, `shown`, `cli`, `program`
          def scope_of(runtime, bluebook, program)
            launcher = LauncherOptions.settings(runtime, bluebook.name)
            options  = LauncherOptions.projection(launcher, program)
            shown = options.merge(audience(runtime, launcher))
            cli = Projector.call(:cli, bluebook: bluebook, options: shown)
            { runtime: runtime, bluebook: bluebook, launcher: launcher, options: options,
              shown: shown, cli: cli, program: program }
          end

          private

          # The attached bluebooks that declare the aggregate a line names, so only those are
          # projected: a line names its aggregate before the first dot, in either spelling
          # (`Landing.land!`, `landing.land!`, `Delivery::Landing.Land`).
          def holders(runtime, argv)
            aggregate = aggregate_word(argv)
            return [] if aggregate.empty?

            attached = attached_bluebooks(runtime).filter_map { |name| runtime.bluebook(name) }
            attached.select { |bluebook| declares?(bluebook, aggregate) }
          end

          def aggregate_word(argv)
            word = argv.find { |entry| !CliRunner::QUERY_WORDS.include?(entry) }.to_s
            return "" unless word.include?(".")

            Naming.snake(unqualified(word.split(".").first))
          end

          # An aggregate's name without the bluebook written before it (`Delivery::Landing`).
          def unqualified(name) = name.split("::").last.to_s

          def declares?(bluebook, aggregate)
            bluebook.aggregates.any? { |declared| Naming.snake(declared.hecks_name) == aggregate }
          end
        end
      end
    end
  end
end
