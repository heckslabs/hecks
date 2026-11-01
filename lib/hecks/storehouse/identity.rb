module Hecks
  module Storehouse
    # The ids a call used, named in its result: the record it addressed, and the references its arguments
    # named. Extended onto `Storehouse`.
    module Identity
      # The arguments that name an id a call used: a run key, an earlier run it refers to, and the checkout
      # and branch it resolved to.
      IDENTITY_KEYS = %i[run from checkout branch].freeze

      # The ids a call used: the record it addressed, and the references its arguments named, each unwrapped
      # to its value. Absent ones are left out.
      # :nodoc:
      def ids_of(request, outcome)
        ids = values_of(request)
        ids[:id] = outcome[:id]
        ids.compact
      end

      # The named arguments of a call, each reduced to its value.
      # :nodoc:
      def values_of(request)
        named_arguments(request).transform_values { |field| value_of(field) }
      end

      # The arguments of a call that name an id, keyed by symbol.
      # :nodoc:
      def named_arguments(request)
        symbolic = request.args.to_h.transform_keys(&:to_sym)
        symbolic.slice(*IDENTITY_KEYS)
      end

      # A stored or caller-supplied field is its value, or the `{value:}` wrapper a word carries.
      # :nodoc:
      def value_of(field)
        return field unless field.is_a?(Hash)

        field.transform_keys(&:to_sym)[:value]
      end
    end
  end
end
