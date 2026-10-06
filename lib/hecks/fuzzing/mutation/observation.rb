require "json"

module Hecks
  module Fuzzing
    module Mutation
      # A history or report reduced to plain values, so two runs compare equal when they did the
      # same thing and differ when they did not.
      module Observation
        PARTS = %i[instances events refusals reactions sagas queries].freeze
        PLAIN = [String, Numeric, true, false, nil].freeze

        module_function

        # @param history [Hash] a replay's history, or a `hecks run` report
        # @return [String] canonical JSON of its observable parts
        def of(history)
          JSON.generate(plain(history.slice(*PARTS)))
        end

        # @return [Object] the value as hashes, arrays, strings, numbers and booleans only
        def plain(value)
          case value
          when Hash then value.sort_by { |key, _| key.to_s }.to_h { |key, item| [key.to_s, plain(item)] }
          when Array then value.map { |item| plain(item) }
          when *PLAIN then value
          else opaque(value)
          end
        end

        # An object that is not plain data: its own hash form when it has one, else its text with
        # the address that would differ between runs taken out.
        def opaque(value)
          value.respond_to?(:to_h) ? plain(value.to_h) : value.to_s.gsub(/0x\h+/, "0x")
        end
      end
    end
  end
end
