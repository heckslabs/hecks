module Hecks
  module Bluebook
    # Builds the runtime graph (aggregates, read models, process managers) from
    # a chapter's declared hash — the pure inverse of `Chapter#to_h`.
    class Assembly
      # Builds the graph the runtime runs from one chapter's declared hash.
      #
      # @param declaration [Hash{Symbol => Object}] a chapter's declarations, in the
      #   shape `Chapter#to_h` spells
      # @return [Bluebook::Chapter] the assembled chapter, with its aggregates, read
      #   models and process managers built and wired
      def self.call(declaration) = new(declaration).bluebook

      # @param declaration [Hash{Symbol => Object}] a chapter's declarations, in the
      #   shape `Chapter#to_h` spells
      def initialize(declaration)
        @declaration = declaration
      end

      # Assembles this instance's declared hash into the chapter's runtime graph.
      #
      # @return [Bluebook::Chapter] the assembled chapter, with its aggregates, read
      #   models and process managers built and wired
      def bluebook
        aggregates = Array(@declaration[:aggregates]).map { |row| AggregateAssembly.new(row).aggregate }
        models     = Array(@declaration[:read_models]).map { |row| Build.call("ReadModel", row) }

        Build.call(
          "Bluebook", @declaration,
          aggregates:       aggregates,
          read_models:      models,
          policies:         reactions(aggregates),
          process_managers: Array(@declaration[:process_managers]).map { |row| process_manager(row) }
        )
      end

      private

      # Hoists each reaction onto the chapter (for the runtime) and also back onto
      # the aggregate head that declared it, per the language's own record of which.
      def reactions(aggregates)
        Array(@declaration[:policies]).map { |row| Build.call("Policy", row) }.each do |reaction|
          next if reaction.aggregate.to_s.empty?

          head = aggregates.find { |held| held.hecks_name == reaction.aggregate }
          head&.policies&.push(reaction)
        end
      end

      def process_manager(row)
        Build.call("ProcessManager", row,
                   handlers: Array(row[:handlers]).map { |leg| handler(leg) })
      end

      def handler(row)
        Build.call("Handler", row,
                   dispatches: Array(row[:dispatches]).map { |leg| dispatch(leg) })
      end

      # `compensates` recurses through this same method (as `handler` does for
      # `dispatches`) since it's itself a nested `DispatchSpec`-shaped hash.
      def dispatch(row)
        compensates = row[:compensates] && dispatch(row[:compensates])
        Build.call("Dispatch", row, compensates: compensates)
      end
    end
  end
end
