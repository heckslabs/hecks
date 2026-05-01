# Hecks::ValidationRules::Structure::ValidPolicyEvents
#
# @domain AcceptanceTest
#
# Produces advisory warnings when policies listen for events that look
# like typos of known events. Cross-domain events are valid — they
# arrive via the shared event bus — so unknown events are only flagged
# if they're suspiciously close to a known event name.
#
#   rule = ValidPolicyEvents.new(domain)
#   rule.warnings  # => ["Policy X listens for 'PlacedOrdr' — did you mean 'PlacedOrder'?"]
#
module Hecks
  module ValidationRules
    module Structure

    class ValidPolicyEvents < BaseRule
      def errors
        []
      end

      def warnings
        result = []
        all_events = @domain.aggregates.flat_map { |a| a.events.map(&:name) }
        return result if all_events.empty?

        collect_policies.each do |policy, context|
          next if all_events.include?(policy.event_name)
          similar = find_similar(policy.event_name, all_events)
          if similar
            result << "#{context} listens for '#{policy.event_name}' — did you mean '#{similar}'?"
          end
        end

        result
      end

      private

      def collect_policies
        policies = []
        @domain.aggregates.each do |agg|
          agg.policies.each { |p| policies << [p, "Policy #{p.name} in #{agg.name}"] }
        end
        @domain.policies.each { |p| policies << [p, "Domain policy #{p.name}"] }
        policies
      end

      def find_similar(name, known)
        known.min_by { |k| levenshtein(name, k) }.then do |best|
          best && levenshtein(name, best) <= 3 && levenshtein(name, best) > 0 ? best : nil
        end
      end

      def levenshtein(a, b)
        m, n = a.length, b.length
        d = Array.new(m + 1) { |i| i }
        (1..n).each do |j|
          prev = d[0]
          d[0] = j
          (1..m).each do |i|
            cost = a[i - 1] == b[j - 1] ? 0 : 1
            temp = d[i]
            d[i] = [d[i] + 1, d[i - 1] + 1, prev + cost].min
            prev = temp
          end
        end
        d[m]
      end
    end
    Hecks.register_validation_rule(ValidPolicyEvents)
    end
  end
end
