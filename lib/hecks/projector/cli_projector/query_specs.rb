module Hecks
  module Projector
    module CliProjector
      # The spec hash of each query and report: the questions a caller reads rather than commands
      # it issues.
      module QuerySpecs
        # A rootless report takes nothing; a rooted one takes the id of the record it
        # is a view of, under the name the model gave that reference.
        def report_spec(bluebook, model)
          arguments =
            if model.reference_target
              [{ path: model.reference_name.to_s, type: "String", required: true,
                 note: "id of the #{model.reference_target} this is a view of" }]
            else
              []
            end

          { command: "#{bluebook.name}.#{model.hecks_name}", kind: :query,
            summary: model.description, arguments: arguments }
        end

        # A question that only reads the aggregate's own records back: it returns no document and
        # filters on nothing but the record's identity ("how one request ended") or its lifecycle
        # status ("every request that was refused"). Each journaled run has such a pair, which a
        # person reads through `hecks <command> --wait` rather than asking for by name, so the help
        # sets them apart with the bookkeeping commands. A query that returns a document, or filters
        # on anything else, is a real question. Only an aggregate that journals its own runs (it has
        # system-role commands, the ones `internal` commands are made of) has such a pair: a
        # release's "every version that was shipped" is a question worth asking by name.
        def bookkeeping_query?(aggregate, query)
          return false if query.returns || query.wheres.empty?
          return false unless journals_own_runs?(aggregate)

          own = own_fields(aggregate)
          query.wheres.all? { |clause| own.include?(clause.field.to_s) }
        end

        # Whether the aggregate has system-role commands, the ones that record its own runs.
        def journals_own_runs?(aggregate)
          aggregate.commands.any? { |command| command.role.to_s == "System" }
        end

        # The fields that are the aggregate's own bookkeeping: its identity and its
        # lifecycle status.
        def own_fields(aggregate)
          Array(aggregate.identified_by).map(&:to_s) + [aggregate.lifecycle&.field.to_s]
        end

        # The spec of one query of an aggregate or of one of its entities.
        def query_spec(bluebook, aggregate, entity, query)
          { command: fqn(bluebook, aggregate, query, entity), kind: :query, group: aggregate.hecks_name,
            internal: entity.nil? && bookkeeping_query?(aggregate, query),
            summary: query.description, arguments: query_arguments(query, aggregate, entity),
            returns: query.returns }
        end

        # The options of the attributes a query declares.
        def query_arguments(query, aggregate, entity)
          Array(query.to_h[:attributes]).flat_map do |declared|
            attribute = query.attributes.find { |a| a.name.to_s == declared[:name].to_s }
            attribute ? options_for(attribute, entity || aggregate, aggregate) : []
          end
        end
      end
    end
  end
end
