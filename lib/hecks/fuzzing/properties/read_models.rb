module Hecks
  module Fuzzing
    module Properties
      # Property: what a read-model ask composes from its references.
      #
      # Leans on `AggregationRecompute`'s own field-reading and foreign-key helpers, which
      # `InvariantsAndAggregation` already extends into `Properties`.
      module ReadModels
        # Every composed read-model ask answered the heads its references name.
        #
        # Each head's rows are recomputed from the instances as the ask saw them: the root is the
        # record the reference names, a many-side head holds the records whose foreign key points at
        # it, and a rootless model reads every record. A model's filtering options apply only to the
        # heads they target. A head with no direct foreign key to the root is inconclusive, and a
        # model that groups, reduces or scopes by tenant is checked by its own properties.
        #
        # @param history [Hash] a replayed history, as returned by `Fuzzing::Replay.call`
        # @return [true, String] true, or a message naming each head that composed otherwise
        def read_model_heads_compose_from_references(history)
          bluebooks = history.fetch(:bluebooks, {})
          offenders = Array(history[:queries]).flat_map { |ask| composition_offenders(ask, bluebooks) }
          offenders.empty? || offenders.uniq.join("; ")
        end

        def composition_offenders(ask, bluebooks)
          bluebook, model = composed_read_model(ask, bluebooks)
          return [] unless model

          answer = ask[:rows].first || {}
          offenders = model.aggregate_heads.filter_map { |head| head_offender(bluebook, model, head, ask) }
          offenders + unexpected_heads(ask[:query], model, answer)
        end

        # The `[bluebook, read_model]` a successful bare-domain ask named; nil when out of scope.
        def composed_read_model(ask, bluebooks)
          return unless answered_read_model_ask?(ask)

          domain, name = ask[:query].split(".", 2)
          bluebook = bluebooks[domain]
          model = bluebook&.read_model(name)
          [bluebook, model] if model && composable?(model)
        end

        # A bare-domain ask (no `::`, so a read model, not an aggregate query) that was answered.
        def answered_read_model_ask?(ask)
          query = ask[:query]
          query.is_a?(String) && !query.include?("::") && !ask[:error] && ask[:rows].is_a?(Array)
        end

        def composable?(model)
          !model.reducing? && model.group_by.empty? && !model.authorization&.tenant
        end

        def unexpected_heads(query, model, answer)
          declared = model.aggregate_heads.map { |head| head[:as] }.sort
          return [] if answer.keys.sort == declared

          ["#{query} answered heads #{answer.keys.sort.inspect}, but declares #{declared.inspect}"]
        end

        def head_offender(bluebook, model, head, ask)
          expected = expected_head_states(bluebook, model, head, ask)
          return unless expected

          answered = answered_ids(head, (ask[:rows].first || {})[head[:as]])
          problem = head_problem(model, head, expected, [answered, ask[:args]])
          "#{ask[:query]} head #{head[:as]}: #{problem}" if problem
        end

        def answered_ids(head, answer)
          rows = head[:many] ? answer.to_a : [answer].compact
          rows.map { |row| row[:id].to_s }
        end

        # The states a head should hold before any option applies, sorted by id; nil when the head
        # has no direct foreign key to the root, which this property cannot read.
        def expected_head_states(bluebook, model, head, ask)
          prefix = "#{bluebook.name}::#{head[:aggregate]}#"
          states = ask[:instances_at].filter_map { |key, state| state.merge(id: key.split("#").last) if key.start_with?(prefix) }
          held = candidate_states(bluebook, model, head, states, ask[:args])
          held&.sort_by { |state| state[:id].to_s }
        end

        def candidate_states(bluebook, model, head, states, args)
          return states if model.reference_target.nil?

          reference_id = args[model.reference_name].to_s
          return states.select { |state| state[:id].to_s == reference_id } if head[:aggregate] == model.reference_target

          referencing_states(bluebook, model, head, states, reference_id)
        end

        # The states whose foreign key holds the reference; nil when the head has no such key.
        def referencing_states(bluebook, model, head, states, reference_id)
          aggregate = bluebook.aggregate(head[:aggregate])
          fields = aggregate ? foreign_key_fields(aggregate, model) : []
          states.select { |state| fields.any? { |field| state[field].to_s == reference_id } } unless fields.empty?
        end

        # `asked` is the answered ids and the ask's arguments, which a `where` value may read.
        def head_problem(model, head, expected, asked)
          answered, args = asked
          return exact_problem(expected, answered) unless model.filtered_head_names.include?(head[:as])

          scoped_problem(model.options_for(head[:as]), expected, answered, args)
        end

        # An untargeted head holds exactly the states the references name, in any order.
        def exact_problem(expected, answered)
          ids = expected.map { |state| state[:id].to_s }
          return if answered.sort == ids.sort

          "answered #{answered.inspect}, but the references compose #{ids.inspect}"
        end

        # A targeted head holds the states its `where` clauses admit; `order_by` only reorders them
        # and a `limit` or `offset` can only narrow them.
        def scoped_problem(options, expected, answered, args)
          kept = expected.select { |state| options.wheres.all? { |clause| head_clause_holds?(clause, state, args) } }
          return exact_problem(kept, answered) unless options.limit || options.offset

          narrowed_problem(kept.map { |state| state[:id].to_s }, answered)
        end

        def narrowed_problem(admitted, answered)
          return if (answered - admitted).empty? && answered.size <= admitted.size

          "answered #{answered.inspect}, beyond what its where clauses admit #{admitted.inspect}"
        end

        # Named for heads: `query_rows.rb` already owns `clause_holds?` in this namespace.
        def head_clause_holds?(clause, state, args)
          Ports::Query::InMemory.holds?(clause, comparable_field(state, clause.field), args)
        end
      end
    end
  end
end
