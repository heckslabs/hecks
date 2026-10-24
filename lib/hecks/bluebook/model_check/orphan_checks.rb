module Hecks
  module Bluebook
    module ModelCheck
      # The check that stands in for `dependent: :destroy`: an aggregate holding `reference_to`
      # another must say, with a policy, what becomes of its rows when that other one's life ends.
      #
      # A record's life ends at an ending state: one its lifecycle reaches, that is not the
      # default, and that no transition leaves. The language has no delete verb, so an ending
      # state is the only way a record ends. A holder that cannot end itself is a record that
      # outlives what it points at by design, a statement or a ledger line, and is not checked.
      # (ADR 0121)
      module OrphanChecks
        # The separator between an aggregate and what it owns in `Aggregate.Name` or
        # `Aggregate::Name`.
        OWNER_SEPARATOR = /::|\./
        # One way an aggregate's life ends: the state, the command that reaches it, and the
        # events that command emits, any of which a policy may hear.
        Ending = Struct.new(:state, :command, :events, keyword_init: true)

        # Flags each pair of a holder that can end and an aggregate it references, for each of
        # the referenced aggregate's endings no policy acts on the holder's rows for.
        #
        # @param bluebook [Bluebook::Chapter] the assembled chapter to check
        # @return [Array<Finding>] one :orphaned_reference warning per unhandled ending
        def orphan_findings(bluebook)
          endings = bluebook.aggregates.to_h { |aggregate| [aggregate.hecks_name, life_endings(aggregate)] }
          bluebook.aggregates.flat_map do |holder|
            endings[holder.hecks_name].empty? ? [] : holder_orphan_findings(bluebook, holder, endings)
          end
        end

        # @param endings [Hash{String => Array<Ending>}] each aggregate's name, to its endings
        # @return [Array<Finding>] the holder's findings, one per unhandled ending of each
        #   aggregate it references
        def holder_orphan_findings(bluebook, holder, endings)
          referenced_attributes(holder).slice(*endings.keys).flat_map do |target, attributes|
            unhandled_endings(bluebook, holder, endings[target], target).map do |ending|
              orphan_finding(holder, target, attributes, ending)
            end
          end
        end

        # @return [Array<Ending>] every transition of the aggregate's own lifecycle that ends it
        def life_endings(aggregate)
          lifecycle = aggregate.lifecycle
          return [] unless lifecycle

          ending = ending_states(lifecycle)
          lifecycle.transitions.filter_map do |command, transition|
            next unless ending.include?(transition.target)

            Ending.new(state: transition.target, command: command, events: emitted_by(aggregate, command))
          end
        end

        # A lifecycle with an unconstrained transition can leave any state, so it has none.
        #
        # @return [Array<String>] the reached states, other than the default, nothing leaves
        def ending_states(lifecycle)
          transitions = lifecycle.transitions.map(&:last)
          return [] unless transitions.all?(&:constrained?)

          left = transitions.flat_map { |transition| Array(transition.from) }
          reachable_states(lifecycle).to_a - [lifecycle.default] - left
        end

        # @return [Hash{String => Array<String>}] each aggregate the holder or one of its entities
        #   references, to the names of the attributes that hold the reference
        def referenced_attributes(holder)
          reference_attributes(holder).group_by(&:target_name)
                                      .transform_values { |attributes| attributes.map { |attribute| attribute.name.to_s } }
        end

        # @return [Array<Bluebook::Attribute>] every reference the holder or its entities hold
        def reference_attributes(holder)
          [holder, *holder.entities].flat_map(&:attributes).select(&:reference?)
        end

        # @return [Array<Ending>] the target's endings with no policy acting on the holder
        def unhandled_endings(bluebook, holder, endings, target)
          endings.reject do |ending|
            bluebook.policies.any? { |policy| handles?(policy, holder, target, ending) }
          end
        end

        # A policy handles an ending when it hears one of the ending's events and fans out over,
        # or triggers a command of, the holder.
        def handles?(policy, holder, target, ending)
          return false unless ending.events.include?(event_name(policy.on_event, target))

          [policy.for_each, policy.trigger_command].compact.any? do |named|
            owner_name(named) == holder.hecks_name
          end
        end

        # @return [String, nil] the event a policy hears, when it is one of `target`'s events
        def event_name(on_event, target)
          owner, event = on_event.to_s.split(OWNER_SEPARATOR, 2)
          event ? (event if owner == target) : owner
        end

        # @return [String] the aggregate a dotted `Aggregate.Name` reference names
        def owner_name(named) = named.to_s.split(OWNER_SEPARATOR).first

        # @return [Array<String>] the event names the aggregate's command emits
        def emitted_by(aggregate, command)
          Array(aggregate.commands.find { |declared| declared.hecks_name == command }&.emits).map(&:to_s)
        end

        def orphan_finding(holder, target, attributes, ending)
          Finding.new(kind: :orphaned_reference, severity: :warning,
                      subject: "#{holder.hecks_name} -> #{target}",
                      message: "#{holder.hecks_name} holds reference_to #{target} (#{attributes.join(", ")}) " \
                               "and #{target} ends at #{ending.state.inspect} by #{ending.command}, " \
                               "but #{orphan_remedy(holder, ending)}")
        end

        def orphan_remedy(holder, ending)
          return "#{ending.command} emits no event, so no policy can act on #{holder.hecks_name}'s rows" if ending.events.empty?

          "no policy on #{ending.events.join(" or ")} acts on #{holder.hecks_name}'s rows; " \
            "add one that fans out over them (for_each \"#{holder.hecks_name}.<query>\") and ends each"
        end
      end
    end
  end
end
