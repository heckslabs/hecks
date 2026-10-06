module Hecks
  module Behaviors
    module Expectations
      # Resolves a bare command or query name to the one dotted FQN that declares it. Extended onto
      # `Expectations`.
      module Qualify
        # Searches every aggregate of every bluebook the suite booted for the one
        # declaring `command`; `on:` narrows the search to one aggregate by name.
        #
        # @param command [String, Symbol] a bare verb, or an already-dotted FQN
        # @param on_aggregate [String, Symbol, nil] the aggregate to search, or nil to
        #   search every aggregate of every bluebook
        # @param bluebooks [Array<Bluebook::Chapter>] every chapter the suite booted
        # @param kind [Symbol] `:command` or `:query`
        # @return [String] `command` unchanged if already dotted, otherwise its resolved
        #   dotted FQN
        # @raise [ArgumentError] if no aggregate declares `command`, or more than one does
        def qualify(command, on_aggregate, bluebooks, kind:)
          return command.to_s if command.to_s.include?(".")

          candidates = qualify_candidates(command, on_aggregate, bluebooks, kind)
          disambiguate_qualified_name(candidates, command, kind, bluebooks)
        end

        # Finds every (bluebook, aggregate) pair that declares a command/query
        # named `command`, narrowed to `on_aggregate` by name when given.
        #
        # @param command [String, Symbol] the bare verb to search for
        # @param on_aggregate [String, Symbol, nil] the aggregate to search, or nil to
        #   search every aggregate of every bluebook
        # @param bluebooks [Array<Bluebook::Chapter>] every chapter the suite booted
        # @param kind [Symbol] `:command` or `:query`
        # @return [Array<Array(Bluebook::Chapter, Bluebook::Aggregate)>] every matching
        #   (chapter, aggregate) pair
        def qualify_candidates(command, on_aggregate, bluebooks, kind)
          members = kind == :query ? :queries : :commands
          aggregate_pairs(bluebooks, on_aggregate)
            .select { |_, agg| agg.public_send(members).any? { |m| m.hecks_name == command.to_s } }
        end

        # @return [Array<Array(Bluebook::Chapter, Bluebook::Aggregate)>] the named aggregate of
        #   each chapter that has it, or every aggregate of every chapter when none is named
        def aggregate_pairs(bluebooks, on_aggregate)
          return bluebooks.flat_map { |bb| bb.aggregates.map { |agg| [bb, agg] } } unless on_aggregate

          bluebooks.filter_map { |bb| (agg = bb.aggregate(on_aggregate)) && [bb, agg] }
        end

        # Resolves a search's candidates to exactly one dotted FQN; zero or more
        # than one both refuse, each with a different message.
        #
        # @param candidates [Array<Array(Bluebook::Chapter, Bluebook::Aggregate)>] the
        #   matching (chapter, aggregate) pairs found by `qualify_candidates`
        # @param command [String, Symbol] the bare verb that was searched for
        # @param kind [Symbol] `:command` or `:query`, for the refusal message
        # @param bluebooks [Array<Bluebook::Chapter>] every chapter the suite booted,
        #   for the refusal message
        # @return [String] the one candidate's dotted FQN
        # @raise [ArgumentError] if `candidates` is empty, or holds more than one
        def disambiguate_qualified_name(candidates, command, kind, bluebooks)
          raise ArgumentError, undeclared_message(command, kind, bluebooks) if candidates.empty?
          raise ArgumentError, ambiguous_message(command, candidates) if candidates.size > 1

          bluebook, aggregate = candidates.first
          "#{bluebook.name}::#{aggregate.name}.#{command}"
        end

        def undeclared_message(command, kind, bluebooks)
          "no aggregate among #{bluebooks.map(&:name).inspect} declares a #{kind} " \
            "named #{command.inspect} — say `on:` if it's ambiguous, or check the spelling"
        end

        def ambiguous_message(command, candidates)
          owners = candidates.map { |bb, agg| "#{bb.name}::#{agg.name}" }
          "#{command.inspect} is declared on more than one aggregate (#{owners.join(", ")}) " \
            "— say `on:` to disambiguate, or use the dotted FQN"
        end
      end
    end
  end
end
