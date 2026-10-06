require_relative "../../naming"
require_relative "../../ports/query/ordering"
require_relative "../../query_specification/field_path"
require_relative "../errors"
require_relative "../needs"
require_relative "../refusal_wording"
require_relative "../tenant_scope"

module Hecks
  module Runtime
    class QueryInterpreter
      # An entity's query: reads the elements of the aggregate's list that holds it, with no
      # native path. Mixed into {QueryInterpreter}.
      module EntityRows
        private

        def entity_rows(domain, aggregate, dotted, args)
          entity_name, query_name = Naming.split_dotted(dotted)
          entity, declared, list_attr = resolve_entity_query(aggregate, entity_name, query_name)
          args = Needs.fill(declared, args, registry: @registry)
          declared = TenantScope.apply(declared, args)

          parent_key = Naming.reference_key(aggregate.hecks_name)
          rows = element_rows(@registry.repository(domain, aggregate).all, list_attr, declared, args, parent_key)
          # Entity queries have no native path, so offset must be applied here.
          paginate(ordered_elements(rows, declared.order_by, declared.null_semantics, parent_key, entity.identity_heads),
                   declared, args)
        end

        # The elements the wheres admit, each keyed by the identity of the record holding it.
        def element_rows(records, list_attr, declared, args, parent_key)
          records.flat_map do |record|
            Array(record[list_attr.name])
              .select { |el| declared.wheres.all? { |w| element_where_holds?(w, el, args) } }
              .map    { |el| { parent_key => record.id }.merge(el) }
          end
        end

        # Resolves a dotted name to the entity, its declared query and the list attribute
        # holding it, refusing with UnknownVerb when any is missing.
        def resolve_entity_query(aggregate, entity_name, query_name)
          entity = aggregate.entities.find { |piece| piece.hecks_name == entity_name } ||
                   raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "entity_unknown",
                                                                 aggregate: aggregate.hecks_name, entity: entity_name))
          declared = entity.query(query_name) ||
                     raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "entity_query_missing",
                                                                   entity: entity_name, query: query_name))
          [entity, declared, entity_list(aggregate, entity_name)]
        end

        def entity_list(aggregate, entity_name)
          aggregate.attributes.find { |a| a.list? && a.type.to_s == entity_name } ||
            raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "entity_holds_no_list",
                                                          aggregate: aggregate.hecks_name, entity: entity_name))
        end

        # FieldPath.dig, not `element[clause.field.to_sym]`: a dotted field such as
        # "price.cents" is never a single key.
        def element_where_holds?(clause, element, args)
          holds?(clause, QuerySpecification::FieldPath.dig(element, clause.field), args)
        end

        # Sub-list rows are symbol-keyed because every adapter decodes through
        # `Ports::Persistence::StateCodec`.
        def cell(row, key) = row[key.to_sym]

        # Orders by parent first, then every key of the piece in declaration order: two
        # entities under different parents can share a sequence, and a composite identity
        # has no single head (`cell(row, nil)` would raise).
        def ordered_elements(rows, order_by, null_semantics, parent_key, entity_keys)
          field = order_by&.field
          Ports::Query::Ordering.apply(
            rows, order_by, null_semantics,
            identity: lambda { |row|
              [row[parent_key].to_s, *Array(entity_keys).map { |key| comparable(cell(row, key)) }]
            }
          ) { |row| comparable(QuerySpecification::FieldPath.dig(row, field)) }
        end
      end
    end
  end
end
