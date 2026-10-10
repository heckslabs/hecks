require_relative "../../bluebook/hecksagon"

module Hecks
  module Adapters
    module Driving
      # Which driving adapters a hecksagon may name with `driven_by`, and the refusal an adapter
      # gets from a domain that left it out.
      #
      # A domain that declares no `driven_by` is open to every adapter. One that declares any is
      # reached through those, and each adapter it omits refuses the domain.
      module Admission
        # The driving adapters a hecksagon can admit.
        ADAPTERS = Bluebook::Hecksagon::DRIVING_ADAPTERS

        # Raised by an adapter that a domain's hecksagon left out of `driven_by`.
        class Refused < StandardError; end

        module_function

        # The sentence a domain gives an adapter it did not admit.
        #
        # @param registry [Runtime::Registry] the booted registry, whose hecksagons are asked
        # @param adapter [String] the adapter reaching in, one of `ADAPTERS`
        # @return [String, nil] the refusal, or nil when every domain admits `adapter`
        def refusal(registry, adapter)
          omitting = registry.hecksagons.values.find { |hecksagon| !hecksagon.driven_by?(adapter) }
          return unless omitting

          "#{omitting.domain} is not driven by #{adapter}: its hecksagon admits only " \
            "#{omitting.driving.join(", ")} (driven_by)"
        end

        # Raises when a domain in `registry` did not admit `adapter`.
        #
        # @param registry [Runtime::Registry] the booted registry
        # @param adapter [String] the adapter reaching in, one of `ADAPTERS`
        # @return [void]
        # @raise [Refused] with the domain's sentence
        def admit!(registry, adapter)
          sentence = refusal(registry, adapter)
          raise Refused, sentence if sentence
        end
      end
    end
  end
end
