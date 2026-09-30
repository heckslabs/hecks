require_relative "../naming"
require_relative "adapter_lookup"
require_relative "../ports/query"
require_relative "../ports/query/ordering"
require_relative "../query_specification/field_path"
require_relative "../query_specification/common/comparison"
require_relative "errors"
require_relative "reference_hop"
require_relative "refusal_wording"
require_relative "tenant_scope"
require_relative "value"

module Hecks
  module Runtime
    # Answers one declared aggregate or entity query against a repository, using a
    # native adapter hook when the store has one and interpreting the query otherwise.
    class QueryInterpreter
      attr_reader :registry

      def initialize(registry)
        @registry = registry
      end

      # Answers one declared aggregate or entity query, preferring a native adapter
      # hook and falling back to interpreting it over every loaded record.
      #
      # @param query_name [String] a declared name, or an entity query's `"Entity.Query"`
      # @return [Array<Hash>] one frozen Hash per matching record, `:id` merged in last
      # @raise [Runtime::UnknownVerb] if `query_name` names no declared query
      # @raise [Runtime::TypeMismatch] if an argument cannot be coerced to its type
      # @raise [Runtime::WiringError] if the aggregate's repository cannot be resolved
      def call(domain, aggregate, query_name, args)
        return entity_rows(domain, aggregate, query_name, args) if query_name.include?(".")

        declared = declared_query(aggregate, query_name)
        args = normalize_args(aggregate, declared, args)
        if (port = aggregate.query_binding(declared.name))
          return answered_from_outside(aggregate, declared, args, port)
        end

        declared = TenantScope.apply(declared, args)
        # Applied after TenantScope so its tenant clause rides through as an ordinary
        # local clause; it is deliberately not propagated into the hop's inner query.
        declared = ReferenceHop.apply(declared, args, registry: @registry, domain: domain, aggregate: aggregate)

        repository = @registry.repository(domain, aggregate)
        # `registry:` lets a `none_in_state` where-clause look up its target aggregate.
        if (native = Ports::Query.execute(repository, declared, args,
                                          context: { domain: domain, aggregate: aggregate, registry: @registry }))
          records = native
          # `id` merges last so an aggregate attribute named `id` cannot clobber the
          # bare identity (see Instance#to_h). Rows are frozen: a mutated row would
          # edit nobody's state and disagree with the store.
          return Freezer.deep(records.map { |record| record.state.merge(id: record.id) })
        end

        Freezer.deep(interpret(repository.all, declared, args, domain: domain))
      end

      # The reference answer: this interpreter's own evaluation, never a native hook.
      # The fuzzer's query oracle diffs it against #call.
      #
      # Hop clauses use a deliberately naive walk (reference_where_holds?), not
      # ReferenceHop's fold; sharing that would blind the oracle to it.
      #
      # @return [Array<Hash>] one Hash per matching record, `:id` merged in last
      # @raise [Runtime::UnknownVerb] if `query_name` names no declared query
      # @raise [Runtime::TypeMismatch] if an argument cannot be coerced to its type
      def reference_call(domain, aggregate, query_name, args)
        return entity_rows(domain, aggregate, query_name, args) if query_name.include?(".")

        declared = declared_query(aggregate, query_name)
        args = normalize_args(aggregate, declared, args)
        # No records to interpret: the adapter is the only answer there is, and the reference
        # takes it through the same shape check, so a diff against #call sees only the adapter.
        port = aggregate.query_binding(declared.name)
        return answered_from_outside(aggregate, declared, args, port) if port

        declared = TenantScope.apply(declared, args)
        reference_interpret(@registry.repository(domain, aggregate).all, declared, args,
                            domain: domain, shape: aggregate)
      end

      private

      # Asks the port's adapter the question the hecksagon bound to this query, by the query's
      # snake-cased name and with its arguments as plain data. Each row of the answer is built as
      # the value object the query `returns`, so an answer that is not that shape is refused
      # before it enters the domain. The aggregate's records are never read.
      #
      # @return [Array<Hash>] the rows as the returned value object's fields, frozen
      # @raise [Runtime::WiringError] if no adapter answers the port or the adapter lacks the method
      # @raise [Runtime::TypeMismatch, Runtime::InvariantViolation, Runtime::UnknownArgument,
      #   Runtime::AbsentArgument] naming the query, if the answer is not its declared shape
      def answered_from_outside(aggregate, declared, args, port)
        asked = "#{aggregate.hecks_name}.#{declared.name}"
        refuse_offered_arguments!(declared, args, asked)
        adapter = AdapterLookup.call(@registry, port.name, asked: asked)
        method  = Naming.snake(declared.name)
        # The real adapter's class is what must answer; a fuzz replay's stand-in refuses instead.
        klass   = AdapterLookup.adapter_class(@registry, port.name, asked: asked)
        AdapterLookup.check_answers!(klass, port.name, method, declared, asked: asked)

        answer = adapter.public_send(method, **Value.materialize(args))
        Freezer.deep(shaped(aggregate, declared, answer, asked))
      end

      # Refuses arguments the adapter cannot be handed: a required one left out, or one the query
      # does not declare. The adapter is asked by keyword, so either would otherwise reach it as a
      # raw ArgumentError.
      #
      # @raise [Runtime::AbsentArgument] if a non-optional declared argument is missing
      # @raise [Runtime::UnknownArgument] if `args` names an argument the query does not declare
      def refuse_offered_arguments!(declared, args, asked)
        names   = declared.attributes.map { |attribute| attribute.name.to_sym }
        offered = args.keys.map(&:to_sym)
        unknown = (offered - names).sort
        unless unknown.empty?
          raise UnknownArgument, RefusalWording.render_site("UnknownArgument", "unknown_args",
                                                            command: asked, unknown: unknown, declared: names)
        end

        required = declared.attributes.reject(&:optional?).map { |attribute| attribute.name.to_sym }
        absent   = (required - offered).sort
        return if absent.empty?

        raise AbsentArgument, RefusalWording.render_site("AbsentArgument", "absent_args",
                                                         command: asked, absent: absent, declared: names)
      end

      # Builds the adapter's answer as the declared value object: one row, or a list of rows for
      # `returns list_of(...)`. A refusal keeps its class and gains the query's name.
      def shaped(aggregate, declared, answer, asked)
        value_object = Value.value_object_for(aggregate, declared.returns_name) or
          raise WiringError, "#{asked} returns #{declared.returns_name.inspect}, which the aggregate " \
                             "declares no value object for"
        offered = declared.returns_list? ? answer : [answer]
        unless offered.is_a?(Array) && offered.all?(Hash)
          raise TypeMismatch, "#{asked} answered outside the domain, but #{answer.class} is not " \
                              "#{declared.returns_list? ? 'a list of' : 'a'} #{value_object.hecks_name} row"
        end

        offered.map { |row| answered_row(value_object, row, aggregate, declared, asked) }
      end

      # One row of an outside answer, built and validated as the returned value object.
      def answered_row(value_object, row, aggregate, declared, asked)
        Value.build(value_object, row, aggregate).to_h
      rescue TypeMismatch, InvariantViolation, UnknownArgument, AbsentArgument => e
        raise e.class, "#{asked} answered outside the domain, but not as its #{declared.returns} — #{e.message}"
      end

      def declared_query(aggregate, query_name)
        aggregate.query(query_name) ||
          raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "no_query",
                                                        aggregate: aggregate.hecks_name, query: query_name))
      end

      def interpret(records, declared, args, domain: nil)
        matched = records.select { |r| declared.wheres.all? { |w| where_holds?(w, r, args, domain: domain) } }
        ordered = ordered(matched, declared.order_by, declared.null_semantics)
        # Offset before limit, as SQL's `LIMIT n OFFSET m` and Ports::Query::InMemory do.
        skipped = declared.offset ? ordered.drop(resolve_query_value(declared.offset.value, args).to_i) : ordered
        capped  = declared.limit ? skipped.first(resolve_query_value(declared.limit.value, args).to_i) : skipped

        capped.map { |r| r.state.merge(id: r.id) }
      end

      # Twin of `interpret` for reference_call: hop clauses go through
      # reference_where_holds?, which `where_holds?` cannot follow.
      def reference_interpret(records, declared, args, domain:, shape:)
        matched = records.select do |r|
          declared.wheres.all? do |w|
            reference_where_holds?(w, r, args, domain: domain, shape: shape)
          end
        end
        ordered = ordered(matched, declared.order_by, declared.null_semantics)
        skipped = declared.offset ? ordered.drop(resolve_query_value(declared.offset.value, args).to_i) : ordered
        capped  = declared.limit ? skipped.first(resolve_query_value(declared.limit.value, args).to_i) : skipped

        capped.map { |r| r.state.merge(id: r.id) }
      end

      # Walks each reference by hand. A nil or dangling reference makes the whole clause
      # false whatever the comparator; comparing nil directly would answer `ne` true.
      def reference_where_holds?(clause, record, args, domain:, shape:)
        step = QuerySpecification::HopPath.next_hop(clause.field, shape.attributes)
        return where_holds?(clause, record, args) unless step

        hop, rest = step
        inner = QuerySpecification::Common::WhereClause.new(field: rest, op: clause.op, value: clause.value)
        held = record[hop.attribute.name]
        reference_ids = hop.attribute.list? ? Array(held) : [held]

        reference_ids.compact.any? do |reference_id|
          target_record = @registry.repository(domain, hop.target).find(reference_id)
          next false unless target_record

          reference_where_holds?(inner, target_record, args, domain: domain, shape: hop.target)
        end
      end

      def entity_rows(domain, aggregate, dotted, args)
        entity_name, query_name = Naming.split_dotted(dotted)
        entity, declared, list_attr = resolve_entity_query(aggregate, entity_name, query_name)
        declared = TenantScope.apply(declared, args)

        parent_key = Naming.reference_key(aggregate.hecks_name)
        rows = @registry.repository(domain, aggregate).all.flat_map do |record|
          Array(record[list_attr.name])
            .select { |el| declared.wheres.all? { |w| element_where_holds?(w, el, args) } }
            .map    { |el| { parent_key => record.id }.merge(el) }
        end

        ordered = ordered_elements(rows, declared.order_by, declared.null_semantics,
                                   parent_key, entity.identity_heads)
        # Entity queries have no native path, so offset must be applied here.
        skipped = declared.offset ? ordered.drop(resolve_query_value(declared.offset.value, args).to_i) : ordered
        declared.limit ? skipped.first(resolve_query_value(declared.limit.value, args).to_i) : skipped
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
        list_attr = aggregate.attributes.find { |a| a.list? && a.type.to_s == entity_name } ||
                    raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "entity_holds_no_list",
                                                                  aggregate: aggregate.hecks_name, entity: entity_name))
        [entity, declared, list_attr]
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

      def where_holds?(clause, record, args, domain: nil)
        holds?(clause, QuerySpecification::FieldPath.dig(record, clause.field), args, record: record, domain: domain)
      end

      # The comparator table is shared with Ports::Query::InMemory#holds? through
      # QuerySpecification::Common::Comparison so the two cannot drift.
      def holds?(clause, held, args, record: nil, domain: nil)
        QuerySpecification::Common::Comparison.holds?(
          clause.op, comparable(held), comparable(resolve_query_value(clause.value, args)), registry: @registry
        )
      end

      def resolve_query_value(value, args)
        value.is_a?(Symbol) ? args[value] : value
      end

      # Coerces with `boundary: false`: a query's declared argument types are not a
      # runtime shape check. The exception is a nil for a required value-object-typed
      # argument, which must refuse as a command argument does; passing it through
      # would run an unfiltered query (a Ruby/Rust divergence).
      #
      # It does not use `Value::Coercion#nil_argument`, which builds a null value object
      # from field defaults and only refuses when a field has none. `null_vo_argument!`
      # refuses like any other wrong-shaped value. Command arguments are untouched.
      def normalize_args(aggregate, declared, args)
        declared.attributes.each_with_object(args.dup) do |attribute, normalized|
          next unless normalized.key?(attribute.name)

          value = normalized[attribute.name]
          normalized[attribute.name] = if checked_vo?(aggregate, attribute, value)
                                         null_vo_argument!(aggregate, attribute)
                                       else
                                         Value.for_attribute(aggregate, attribute, value, boundary: false)
                                       end
        end
      end

      def checked_vo?(aggregate, attribute, value)
        return false unless value.nil?
        return false if attribute.optional? || attribute.list? || attribute.reference?
        return false unless aggregate.respond_to?(:value_object)

        !Value.value_object_for(aggregate, attribute.type).nil?
      end

      # Refuses a nil for a value-object argument; never absorbs it via field defaults.
      def null_vo_argument!(aggregate, attribute)
        value_object = Value.value_object_for(aggregate, attribute.type)
        Value.build(value_object, Value.fields_for(value_object, attribute.name, nil), aggregate)
      end

      def comparable(value) = QuerySpecification::Common::Comparison.comparable(value)

      # FieldPath.dig, not `record[field]`: a dotted order_by is one symbol key that
      # `Instance#[]` never holds, so it would sort by all-nil.
      def ordered(records, order_by, null_semantics = nil)
        field = order_by&.field
        Ports::Query::Ordering.apply(records, order_by, null_semantics,
                                     identity: ->(record) { record.id.to_s }) do |record|
          comparable(QuerySpecification::FieldPath.dig(record, field))
        end
      end
    end
  end
end
