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
          bluebook.modules.map(&:name).uniq.find { |name| Naming.snake(name) == word }
        end

        # The specs of the aggregates `name` groups; every spec when no module is asked for.
        def in_module(bluebook, specs, name)
          return specs unless name

          members = bluebook.modules.select { |row| row.name == name }.map(&:aggregate)
          specs.select { |_, spec| members.include?(spec[:group]) }
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
