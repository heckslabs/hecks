require_relative "../errors"
require_relative "../row_sweep"

module Hecks
  module Runtime
    class PolicyInterpreter
      # A `for_each` policy: asks a query which rows the event concerns, and fires the trigger
      # once per row through the {RowSweep} a bulk run shares. Mixed into {PolicyInterpreter}.
      module FanOut
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
          aggregate = row_sweep.query_aggregate(query_domain, aggregate_name, verb: policy.for_each)
          # The query reads the event, never the `with:` projection: it asks which rows.
          query_args = for_each_query_args(aggregate.query(query_name), event)
          rows = row_sweep.rows(query_domain, aggregate, query_name, query_args)
          [rows, row_sweep.addressing_key_for(target, aggregate_name, label: "for_each's own trigger")]
        end

        def row_sweep = @row_sweep ||= RowSweep.new(@registry)

        # The event's own identity is not in its payload, so a query argument named
        # after an identity head of the emitting aggregate is filled from `event.id`.
        # Without it the query silently sees nothing. Never overrides a payload value.
        def for_each_query_args(query, event)
          args = event.payload.transform_keys(&:to_sym)
          construct = query && emitting_construct(event)
          return args unless construct

          lent_attributes(query, construct, args).each { |attribute| args[attribute.name] = event.id }
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
