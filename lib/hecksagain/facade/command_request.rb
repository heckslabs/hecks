require_relative "../runtime/errors"

module Hecksagain
  module Facade
    # Turns an external command request into the dispatcher's receiver/payload
    # envelope. Human-facing doors may accept their old flat id spelling at
    # the edge, but every call leaving this boundary has one shape:
    #
    #   aggregate command: { to: "record-id", with: { declared: "facts" } }
    #   entity command:    { to: { aggregate: "...", entity: "..." },
    #                        with: { declared: "facts" } }
    #
    # The command interpreter remains the authority on which facts are
    # declared. This helper only prevents routing fields from leaking into the
    # fact payload and gives every external door the same wire contract.
    module CommandRequest
      module_function

      def normalize(input, receiver:, legacy_receiver: nil)
        request = symbolize(input)
        unless request.is_a?(Hash)
          raise Runtime::TypeMismatch, "a command request must be a hash"
        end

        route, facts = split(request, receiver: receiver, legacy_receiver: legacy_receiver)
        validate_route!(route, receiver)

        envelope = { with: facts }
        envelope[:to] = route if receiver
        envelope
      end

      def split(request, receiver:, legacy_receiver:)
        if request.key?(:with)
          loose = request.keys - [:to, :with]
          unless loose.empty?
            raise Runtime::TypeMismatch,
                  "an explicit command envelope takes routing in to: and facts in with:, not loose #{loose.sort.join(', ')}"
          end

          facts = request[:with]
          raise Runtime::TypeMismatch, "with: must be a hash of command facts" unless facts.is_a?(Hash)

          return [request[:to], facts]
        end

        flat  = request.dup
        route = flat.delete(:to)
        route = take_legacy_route(flat, receiver, legacy_receiver) if route.nil?
        [route, flat]
      end
      private_class_method :split

      def take_legacy_route(flat, receiver, legacy_receiver)
        return unless legacy_receiver

        if receiver == :aggregate
          return flat.delete(legacy_receiver.to_sym)
        end

        return unless receiver == :entity && legacy_receiver.is_a?(Hash)

        aggregate_key = legacy_receiver.fetch(:aggregate).to_sym
        entity_key    = legacy_receiver.fetch(:entity).to_sym
        return unless flat.key?(aggregate_key) || flat.key?(entity_key)

        { aggregate: flat.delete(aggregate_key), entity: flat.delete(entity_key) }
      end
      private_class_method :take_legacy_route

      def validate_route!(route, receiver)
        case receiver
        when nil
          raise Runtime::TypeMismatch, "this command does not take a receiver in to:" unless route.nil?
        when :aggregate
          if route.nil? || route.to_s.empty? || route.is_a?(Hash)
            raise Runtime::TypeMismatch, "to: must name the receiving aggregate identity"
          end
        when :entity
          unless route.is_a?(Hash)
            raise Runtime::TypeMismatch, "to: for an entity command must contain aggregate: and entity:"
          end

          extra = route.keys - [:aggregate, :entity]
          missing = [:aggregate, :entity].select { |key| route[key].nil? || route[key].to_s.empty? }
          unless extra.empty? && missing.empty?
            raise Runtime::TypeMismatch, "to: for an entity command must contain only aggregate: and entity:"
          end
        else
          raise ArgumentError, "unknown receiver kind #{receiver.inspect}"
        end
      end
      private_class_method :validate_route!

      def symbolize(value)
        case value
        when Hash then value.to_h { |key, nested| [key.to_sym, symbolize(nested)] }
        when Array then value.map { |nested| symbolize(nested) }
        else value
        end
      end
      private_class_method :symbolize
    end
  end
end
