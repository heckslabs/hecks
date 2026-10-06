require_relative "../../naming"

module Hecks
  module Projector
    module CliProjector
      # The command-line names of a projection: who claims which name, how a command is
      # qualified, and the launcher names a chapter gives its commands.
      module Claims
        # Claims the commands and questions of one aggregate and its entities and ports.
        #
        # @param commands [Hash{String => Hash}] the command map, mutated in place
        # @param questions [Hash{String => Hash}] the question map, mutated in place
        # @param bluebook [Bluebook::Chapter] the booted domain
        # @param aggregate [Bluebook::Aggregate] the aggregate to claim
        # @return [void]
        def claim_aggregate(commands, questions, bluebook, aggregate)
          claim_members(commands, questions, bluebook, aggregate, nil)
          aggregate.entities.each { |entity| claim_members(commands, questions, bluebook, aggregate, entity) }

          # Port operations dispatch by the same name as a command, so they are commands too.
          aggregate.ports.each do |port|
            port.operations.each { |o| claim(commands, name_for(aggregate, o), port_spec(bluebook, aggregate, port, o)) }
          end
        end

        # Claims the commands and queries one aggregate or one of its entities declares.
        def claim_members(commands, questions, bluebook, aggregate, entity)
          owner = entity || aggregate
          owner.commands.each do |c|
            claim(commands, name_for(aggregate, c, entity), command_spec(bluebook, aggregate, entity, c))
          end
          owner.queries.each do |q|
            claim(questions, name_for(aggregate, q, entity), query_spec(bluebook, aggregate, entity, q))
          end
        end

        # Claims each report under its chapter-qualified name. A report belongs to the chapter,
        # not an aggregate, so it is addressed `Chapter.Report` (one dot) where a query is
        # `Chapter::Aggregate.Query`.
        def claim_reports(questions, bluebook)
          bluebook.read_models.each do |model|
            claim(questions, Naming.snake(model.hecks_name), report_spec(bluebook, model))
          end
        end

        # Sets `:short` on each spec to its full `aggregate.command` name: a command is always
        # called with its aggregate, so adding a command elsewhere never changes what a call means.
        #
        # @param specs [Hash{String => Hash}] the command or query map, mutated in place
        # @return [void]
        def qualify(specs)
          specs.each { |name, spec| spec[:short] = name }
        end

        # Marks the `run` key of each creating command `minted`: optional, and never filled by a
        # bare word, since the launcher makes one when it is left out.
        def mint_run_keys(commands)
          commands.each_value do |spec|
            next unless spec[:creates]

            spec[:arguments] = spec[:arguments].map do |argument|
              next argument unless argument[:path] == "run.value"

              argument.merge(required: false, minted: true, note: "minted when omitted")
            end
          end
        end

        # Sets the display name of every spec in each map: its full name, then renamed by `names`.
        #
        # @param maps [Array<Hash{String => Hash}>] the command and question maps, mutated in place
        # @param names [Hash, nil] the chapter's launcher names
        # @return [void]
        def display_names(maps, names)
          maps.each do |specs|
            qualify(specs)
            rename(specs, names)
          end
        end

        # Gives a command the launcher name a chapter's `names` table assigns it.
        #
        # The alias replaces the short name in help, so it is listed once; the spelling it
        # replaced keeps working (`:short_was`, read by `aliases`). A table entry naming no
        # command in `specs` belongs to the other namespace and is skipped.
        #
        # @param specs [Hash{String => Hash}] the command or question map, mutated in place
        # @param names [Hash{String, Symbol => String, Symbol}, nil] launcher name to command name
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if a launcher name is already another command's name
        def rename(specs, names)
          Hash(names).each do |launcher_name, command|
            _, spec = specs.find { |key, candidate| [key, candidate[:short]].include?(command.to_s) }
            next unless spec

            reserve_launcher_name(specs, launcher_name)
            spec[:short_was] = spec[:short]
            spec[:short]     = launcher_name.to_s
          end
        end

        # Refuses a launcher name that is already some command's short name.
        def reserve_launcher_name(specs, launcher_name)
          return unless specs.values.any? { |spec| spec[:short] == launcher_name.to_s }

          raise Bluebook::DSL::Malformed, "launcher name #{launcher_name.to_s.inspect} is already a command"
        end

        # Maps every accepted spelling (full name, `:short` and a renamed command's old name)
        # to the full name.
        def aliases(specs)
          specs.each_with_object({}) do |(name, spec), map|
            map[name]         = name
            map[spec[:short]] = name
            map[spec[:short_was]] = name if spec[:short_was]
          end
        end

        # Stores `spec` under `name`, refusing a second claim rather than silently
        # keeping whichever command was walked first.
        #
        # @raise [Bluebook::DSL::Malformed] if `name` is already claimed by another command
        def claim(commands, name, spec)
          if commands.key?(name)
            raise Bluebook::DSL::Malformed,
                  "two commands project to the command-line name #{name.inspect}: " \
                  "#{commands[name][:command]} and #{spec[:command]} — rename one"
          end

          commands[name] = spec
        end

        # The dotted command-line name, `aggregate[.entity].command`, snake-cased.
        def name_for(aggregate, command, entity = nil)
          parts = [Naming.snake(aggregate.hecks_name)]
          parts << Naming.snake(entity.hecks_name) if entity
          parts << Naming.snake(command.hecks_name)
          parts.join(".")
        end

        # The command's language name, `Chapter::Aggregate[.Entity].Verb`, for help text.
        def fqn(bluebook, aggregate, command, entity = nil)
          [bluebook.name, "::", aggregate.hecks_name, ".",
           entity ? "#{entity.hecks_name}." : "", command.hecks_name].join
        end
      end
    end
  end
end
