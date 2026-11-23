# frozen_string_literal: true

module Hecks
  module Adapters
    class MachineProfiling
      # Applies the declared `Formula` and `Bound` rows to a profile. It holds no formula of its
      # own: change a row and the value changes.
      module Derivation
        module_function

        # @param setting [String] a setting a `Formula` row names
        # @param profile [Hash{Symbol => Numeric}] the measures of a profile
        # @param rows [Hash] {Rows}
        # @return [Numeric, nil] the value inside its bounds; nil when no row names the setting
        def value(setting, profile, rows)
          formula = rows[:formulas][setting]
          return nil unless formula

          bounded(setting, raw(formula, profile, corrected(setting, rows)), profile, rows)
        end

        # @return [Hash{String => Numeric}] every derived setting
        def all(profile, rows) = rows[:formulas].keys.to_h { |setting| [setting, value(setting, profile, rows)] }

        def raw(formula, profile, factor = 1.0)
          amount = profile.fetch(formula[:measure].to_sym) * formula[:times] * factor / formula[:divisor]
          amount /= profile.fetch(formula[:per].to_sym) unless formula[:per].empty?
          formula[:whole] == "yes" ? amount.floor : amount
        end

        # The kept turn's factor for the setting; one when this machine has kept none.
        def corrected(setting, rows) = (rows[:corrections] || {}).fetch(setting, 1.0)

        def bounded(setting, amount, profile, rows)
          bound = rows[:bounds][setting]
          return amount unless bound

          held = amount.clamp(bound[:least], [most_of(bound, profile), bound[:least]].max)
          rows[:formulas][setting][:whole] == "yes" ? held.to_i : held.to_f
        end

        def most_of(bound, profile)
          named = bound[:most_measure]
          named.empty? ? bound[:most] : [bound[:most], profile.fetch(named.to_sym)].min
        end
      end
    end
  end
end
