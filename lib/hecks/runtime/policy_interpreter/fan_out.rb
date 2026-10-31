require_relative "../errors"
require_relative "../row_sweep"

module Hecks
  module Runtime
    class PolicyInterpreter
      # A `for_each` policy: asks a query which rows the event concerns, and fires the trigger
      # once per row through the {RowSweep} a bulk run shares. Mixed into {PolicyInterpreter}.
      module FanOut
        # The bare scalar types a `for_each` query may declare as an argument.
        SCALAR_ARGUMENT_TYPES = %w[String Integer Float].freeze

        private

        # Runs the `for_each` query against the event payload and fires the trigger once
        # per row, addressing each row by `addressing_key_for`. A refusal is recorded per
        # row and the fan-out continues; a crash resolving the query or an unaddressable
        # target is one top-level defect for the policy.
        def deliver_for_each(policy, event, domain, target, record)
          return nil unless where_holds?(policy, event)

          rows, reference_key = for_each_rows(policy, event, domain, target)
          Array(rows).map do |row|
            args = trigger_args(policy, event, { reference_key => row[:id] }, row)
            deliver_for_each_row(target, record.merge(for_row: row[:id]), args, policy, event)
          end
        rescue *DOMAIN_REFUSALS => e
          record.merge(delivered: false, reason: e.message)
        rescue StandardError => e
          defect(policy, event, record, e, "resolving for_each #{policy.for_each}")
        end

        # The rows the `for_each` query answers, and the key by which the trigger addresses a row.
        def for_each_rows(policy, event, domain, target)
          query_domain, aggregate_name, query_name = policy.for_each_route(domain)
          return read_model_rows(event, query_domain, aggregate_name, target) if query_name.nil?

          aggregate = row_sweep.query_aggregate(query_domain, aggregate_name, verb: policy.for_each)
          # The query reads the event, never the `with:` projection: it asks which rows.
          query_args = for_each_query_args(aggregate.query(query_name), event)
          rows = row_sweep.rows(query_domain, aggregate, query_name, query_args)
          [rows, row_sweep.addressing_key_for(target, aggregate_name, label: "for_each's own trigger")]
        end

        # A `for_each` naming a read model fans out over the rows of the head the trigger addresses:
        # the read model's many-side head whose aggregate the target command takes a reference to.
        # The read model is answered from the event as a query is, and each row keeps its own `id`.
        def read_model_rows(event, domain, model_name, target)
          model = @registry.bluebook(domain)&.read_model(model_name)
          raise UnknownVerb, "for_each #{model_name.inspect} names no query or read model in #{domain}" unless model

          head = addressed_head(model, target, model_name)
          answer = ReadModelInterpreter.new(@registry).call(domain, model, for_each_query_args(nil, event))
          key = row_sweep.addressing_key_for(target, head[:aggregate], label: "for_each's own trigger")
          [Array(answer.first[head[:as]]), key]
        end

        # The one many-side head of `model` that `target` addresses. Refused unless exactly one
        # does, since two candidate row kinds would not say which one the trigger acts on.
        def addressed_head(model, target, model_name)
          command = row_sweep.target_command(target, label: "for_each's own trigger")
          heads = model.aggregate_heads.select do |head|
            head[:many] && command.addressing_key_for(head[:aggregate])
          end
          return heads.first if heads.one?

          raise ArgumentError, "for_each #{model_name} must have exactly one row kind that #{target} can address, " \
                               "found #{heads.size}"
        end

        def row_sweep = @row_sweep ||= RowSweep.new(@registry)

        # The event's own identity is not in its payload, so a query argument named
        # after an identity head of the emitting aggregate is filled from `event.id`.
        # Without it the query silently sees nothing. Never overrides a payload value.
        def for_each_query_args(query, event)
          args = event.payload.transform_keys(&:to_sym)
          construct = query && emitting_construct(event)
          if construct
            lent_attributes(query, construct, args).each { |attribute| args[attribute.name] = event.id }
            lent_references(query, construct, event, args)
          end
          unwrap_scalar_arguments(query, args)
        end

        # A query argument named after a `reference_to` the emitting aggregate declares takes the
        # emitting record's stored value for that reference, because an event's payload need not
        # carry it (a command with no attributes emits an empty payload). Never overrides a payload
        # value, and an argument with no matching reference is left alone.
        def lent_references(query, construct, event, args)
          references = unfilled_reference_names(query, construct, args)
          record = emitter_record(construct, event) if references.any?
          references.each { |name| lend_reference(args, record, name) } if record
          args
        end

        def lend_reference(args, record, name)
          value = stored_value(record, name)
          args[name] = value unless value.nil?
        end

        # The emitting aggregate's reference attributes that the query reads and the payload lacks.
        def unfilled_reference_names(query, construct, args)
          queried = query.attributes.map { |attribute| attribute.name.to_sym } - args.keys
          construct.attributes.select(&:reference?).map { |attribute| attribute.name.to_sym } & queried
        end

        # The emitting record as stored, or nil when the event carries no identity to load it by.
        def emitter_record(construct, event)
          return nil if event.id.to_s.empty?

          @registry.read_repository(event_domain(event), construct).find(event.id)
        end

        def event_domain(event)
          domain, _name = event.aggregate.to_s.split("::", 2)
          domain
        end

        def stored_value(record, name)
          record.public_send(name) if record.respond_to?(name)
        end

        # A bare-scalar query argument takes the one value its single-field value object carries:
        # the payload hands over the object, but the query declares the scalar, and a query's
        # argument is shape-checked against its declared type.
        def unwrap_scalar_arguments(query, args)
          return args unless query

          query.attributes.each do |attribute|
            value = args[attribute.name]
            next unless value.is_a?(Hash) && value.size == 1 && SCALAR_ARGUMENT_TYPES.include?(attribute.type.to_s)

            args[attribute.name] = value.values.first
          end
          args
        end

        # The query arguments named for an identity head the payload does not already carry.
        def lent_attributes(query, construct, args)
          heads = construct.identity_heads.map(&:to_s)
          query.attributes.select { |attribute| heads.include?(attribute.name.to_s) && !args.key?(attribute.name) }
        end

        def deliver_for_each_row(target, row_record, args, policy, event)
          return depth_refusal(row_record) if @dispatcher.reaction_depth_reached?

          # The row key is already merged by `trigger_args`, so a projection can name it.
          row_sweep.deliver(row_record) { @dispatcher.reenter(target, **reaction_invocation(target, args, policy, event)) }
        end
      end
    end
  end
end
