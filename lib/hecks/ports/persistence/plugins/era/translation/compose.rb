# frozen_string_literal: true

require_relative "../../../../../bluebook/translation"
require_relative "compose_render"

module Hecks
  module Translation
    # Composes the chain of translation edges from a held era to the current shape into the one
    # edge that leads straight there. Rendering the edge as `.bluebook` text is `ComposeRender`.
    #
    # Composition is exact only where the chain is unambiguous. An aggregate's field rules (renames,
    # drops, derives and the rest) may appear in one step of the chain; two steps' rules on the same
    # aggregate would need their order and names reconciled, and that is a decision for a person.
    # Aggregate names are followed through every step, so a rename in any step survives into the
    # composed edge as `was:`.
    module Compose
      # The field-level rule lists a `Bluebook::TranslationAggregate` carries.
      FIELD_RULES = %i[renames moves converts drops retypes derives rekeys backfills splits].freeze

      # The rules no rendering covers yet; a chain that carries one is refused, not guessed at.
      UNRENDERABLE = %i[rekeys splits].freeze

      module_function

      # Walks the edges that lead one shape label to the next until the current shape.
      #
      # @param translations [Array<Bluebook::Translation>] every loaded edge, any domain
      # @param domain [String] the domain whose edges count
      # @param from [String] the held era's shape label
      # @param to [String] the current shape label
      # A held era whose label is the current one but whose projection differs has no chain to walk:
      # its one step is the edge from that label to itself, when such an edge exists.
      #
      # @return [Array<Bluebook::Translation>] the edges in order; empty when none leads `from` to
      #   `to`
      # @raise [Runtime::WiringError] when a step has no edge, has two, or the walk loops
      def chain(translations, domain:, from:, to:)
        return self_edges(translations, domain, from) if from == to

        steps = []
        label = from
        until label == to
          step = next_step(translations, domain, label, to)
          raise_loop!(domain, step.to) if [from, *steps.map(&:to)].include?(step.to)
          steps << step
          label = step.to
        end
        steps
      end

      # @return [Bluebook::Translation] the one edge from the first step's origin to the last step's
      #   target
      # @raise [Runtime::WiringError] when a step's rules cannot be composed into one edge
      def compose(domain:, from:, to:, chain:)
        refuse_unrenderable!(chain)
        origins, retired, ruled = track_chain(chain)
        Bluebook::Translation.new(domain: domain, from: from, to: to,
                                  aggregates: composed_aggregates(origins, ruled),
                                  retired: retired.reject { |name| origins.key?(name) })
      end

      def self_edges(translations, domain, label)
        translations.select { |edge| edge.domain == domain && edge.from == label && edge.to == label }
      end

      # @return [Bluebook::Translation] the step leaving `label`, the only one that does
      # @raise [Runtime::WiringError] when none leaves it or two do
      def next_step(translations, domain, label, to)
        leaving = translations.select { |edge| edge.domain == domain && edge.from == label }
        refuse_broken!(domain, label, to) if leaving.empty?
        refuse_forked!(domain, label, leaving) if leaving.size > 1
        leaving.first
      end

      def refuse_broken!(domain, label, to)
        raise Runtime::WiringError,
              "cannot compose #{domain}: the edge chain is broken at #{label} — no translation leads " \
              "#{label} onward to #{to}; restore translations/ or write the missing edge"
      end

      def refuse_forked!(domain, label, leaving)
        raise Runtime::WiringError,
              "cannot compose #{domain}: #{leaving.size} translations leave #{label} " \
              "(#{leaving.map(&:to).join(", ")}); one must go before the chain can compose"
      end

      def raise_loop!(domain, label)
        raise Runtime::WiringError, "cannot compose #{domain}: the edge chain loops back to #{label}"
      end

      def refuse_unrenderable!(chain)
        chain.each do |step|
          step.aggregates.each do |aggregate|
            next if UNRENDERABLE.all? { |rule| aggregate.public_send(rule).empty? }

            raise Runtime::WiringError,
                  "cannot compose #{step.domain}: #{aggregate.name} carries a rekey or split, which " \
                  "composes by hand; write the composed edge yourself"
          end
        end
      end

      # Follows each aggregate from its held name to its current one, and finds the one step that
      # carries field rules for each origin.
      #
      # @return [Array(Hash, Array<String>, Hash)] origins keyed by current name, every retired
      #   name,
      #   and the aggregate carrying field rules for each origin
      def track_chain(chain)
        state = { origins: {}, retired: [], ruled: {} }
        chain.each_with_index { |step, index| track_step(state, step, index) }
        [state[:origins], state[:retired].uniq, state[:ruled].transform_values(&:last)]
      end

      def track_step(state, step, index)
        step.aggregates.each { |aggregate| track_aggregate(state, step.domain, aggregate, index) }
        state[:retired].concat(step.retired)
      end

      def track_aggregate(state, domain, aggregate, index)
        origin = track(state[:origins], aggregate)
        return if FIELD_RULES.all? { |rule| aggregate.public_send(rule).empty? }

        refuse_two_steps!(domain, aggregate.name, state[:ruled][origin], index) if state[:ruled][origin]
        state[:ruled][origin] = [index, aggregate]
      end

      # Records an aggregate under its current name, keeping the name it was held under.
      def track(origins, aggregate)
        previous = aggregate.was || aggregate.name
        origin = origins.delete(previous) || previous
        origins[aggregate.name] = origin
      end

      # Builds the composed aggregates: one per aggregate that was renamed or carries field rules.
      def composed_aggregates(origins, ruled)
        origins.filter_map do |name, origin|
          source = ruled[origin]
          next if source.nil? && origin == name

          composed_aggregate(name, origin, source)
        end
      end

      def refuse_two_steps!(domain, name, earlier, index)
        raise Runtime::WiringError,
              "cannot compose #{domain}: #{name} has field rules in steps #{earlier.first + 1} and " \
              "#{index + 1} of the chain; compose those by hand"
      end

      def composed_aggregate(name, origin, source)
        rules = source ? FIELD_RULES.to_h { |rule| [rule, source.public_send(rule)] } : {}
        Bluebook::TranslationAggregate.new(name: name, was: (origin == name ? nil : origin), **rules)
      end
    end
  end
end
