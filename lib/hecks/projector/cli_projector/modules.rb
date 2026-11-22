module Hecks
  module Projector
    module CliProjector
      # The help of one module of a bluebook (ADR 0163): the commands and queries of the
      # aggregates the module groups, listed under the module's name and vision.
      module Modules
        # The module a word names, in the bluebook's own spelling: `deliver` for `Deliver`.
        #
        # @param bluebook [Bluebook::Declaration] the bluebook whose modules are searched
        # @param word [String, nil] a word of the command line
        # @return [String, nil] the module's name, or nil when the bluebook has none by that word
        def module_named(bluebook, word)
          module_names(bluebook).find { |name| Naming.snake(name) == word }
        end

        # Each module's name once, in declaration order.
        def module_names(bluebook)
          bluebook.modules.map(&:name).uniq
        end

        # The specs of the aggregates `name` groups; every spec when no module is asked for.
        def in_module(bluebook, specs, name)
          return specs unless name

          members = bluebook.modules.select { |row| row.name == name }.map(&:aggregate)
          specs.select { |_, spec| members.include?(spec[:group]) }
        end

        # The short help's body: each module's word and the first sentence of its vision, then the
        # line saying where the commands and queries are listed in full.
        def brief_lines(bluebook, program)
          rows = module_summaries(bluebook)
          width = widest(rows.keys)
          ["modules (`#{program} <module>` lists its commands and queries):",
           *rows.map { |word, vision| "  #{word.ljust(width)}  #{vision}" },
           "", "  #{program} --all                  every command and query, in full",
           "  #{program} <query> --since[=<hash>]  ask again for one line when nothing changed"]
        end

        # The length of the longest word.
        def widest(words) = words.map(&:length).max.to_i

        # Each module's word, with the first sentence of its vision cut to fit one line.
        def module_summaries(bluebook)
          module_names(bluebook).to_h do |name|
            vision = bluebook.modules.find { |row| row.name == name }.vision
            [Naming.snake(name), CliAudience.clipped(first_sentence(vision), 72)]
          end
        end

        # A module's heading: its word and its vision, then the two ways to call what it lists.
        def module_header(bluebook, name, program)
          vision = bluebook.modules.find { |row| row.name == name }.vision
          ["#{Naming.snake(name)} — #{vision}", "",
           "  #{program} <Aggregate.command>! [name=value …]    do something",
           "  #{program} <Aggregate.query> [name=value …]       read something", ""]
        end
      end
    end
  end
end
