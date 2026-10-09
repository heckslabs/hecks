require_relative "../../naming"
require_relative "../errors"
require_relative "../query_interpreter"
require_relative "../refusal_wording"

module Hecks
  module Runtime
    class PolicyInterpreter
      # A `for_each` policy: asks a query which rows the event concerns, and fires the trigger
      # once per row. Mixed into {PolicyInterpreter}.
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
          aggregate = resolve_query_aggregate(query_domain, aggregate_name, policy.for_each)
          # The query reads the event, never the `with:` projection: it asks which rows.
          query_args = for_each_query_args(aggregate.query(query_name), event)
          rows = QueryInterpreter.new(@registry).call(query_domain, aggregate, query_name, query_args)
          [rows, addressing_key_for(target, aggregate_name)]
        end

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

        # Resolves `target` back to its declared command and asks it how a row of
        # `aggregate_name` addresses it. Raises rather than guessing when the command is
        # unresolvable or cannot be addressed: a domain-authoring mistake to surface.
        def addressing_key_for(target, aggregate_name)
          target_domain, target_aggregate_name, target_command_name = Naming.split_verb(target)
          command = @registry.bluebook(target_domain)&.aggregate(target_aggregate_name)&.command(target_command_name)
          raise UnknownVerb, "for_each's own trigger #{target.inspect} does not resolve to a declared command" unless command

          key = command.addressing_key_for(aggregate_name)
          return key if key

          raise ArgumentError,
                "#{target} cannot be addressed by a row of #{aggregate_name} — it declares no self-reference to " \
                "#{aggregate_name} and no reference-typed attribute targeting it"
        end

        def deliver_for_each_row(target, row_record, args, policy, event)
          return depth_refusal(row_record) if @door.reaction_depth_reached?

          # The row key is already merged by `trigger_args`, so a projection can name it.
          @door.reenter(target, **reaction_invocation(target, args, policy, event))
          row_record.merge(delivered: true)
        rescue *DOMAIN_REFUSALS => e
          row_record.merge(delivered: false, reason: e.message)
        end

        def resolve_query_aggregate(domain, aggregate_name, verb)
          bluebook = @registry.bluebook(domain) ||
                     raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "no_domain", domain: domain, verb: verb))
          bluebook.aggregate(aggregate_name) ||
            raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "no_aggregate",
                                                          domain: domain, aggregate: aggregate_name))
        end
      end
    end
  end
end
