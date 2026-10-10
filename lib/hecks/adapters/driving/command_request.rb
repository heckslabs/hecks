require_relative "../../runtime/errors"

module Hecks
  module Adapters
    module Driving
      # Turns an external command request into the dispatcher's `to:`/`with:` envelope.
      #
      #   aggregate command: { to: "record-id", with: { declared: "facts" } }
      #   entity command:    { to: { aggregate: "...", entity: "..." }, with: { ... } }
      module CommandRequest
        module_function

        # Splits a request, envelope or flat Hash, into routing (`to:`) and facts (`with:`),
        # symbolizing keys at every depth; in a flat Hash all but the receiver are facts.
        #
        # @param input [Hash] the request, with String or Symbol keys
        # @param receiver [Symbol, nil] `:aggregate`, `:entity`, or `nil` for a command with none
        # @param legacy_receiver [Symbol, String, Hash, nil] the flat key that may carry the
        #   receiver instead of `to:`: a name for `:aggregate`, `{ aggregate:, entity: }` for
        #   `:entity`
        # @return [Hash{Symbol => Object}] `{ with: facts }`, plus `to:` when `receiver` is set
        # @raise [Runtime::TypeMismatch] if the request is malformed or the route does not fit
        #   the receiver kind
        # @raise [ArgumentError] if `receiver` is not `nil`, `:aggregate` or `:entity`
        def normalize(input, receiver:, legacy_receiver: nil)
          request = symbolize(input)
          raise Runtime::TypeMismatch, "a command request must be a hash" unless request.is_a?(Hash)

          route, facts = split(request, receiver: receiver, legacy_receiver: legacy_receiver)
          validate_route!(route, receiver)

          envelope = { with: facts }
          envelope[:to] = route if receiver
          envelope
        end

        def split(request, receiver:, legacy_receiver:)
          return split_envelope(request) if request.key?(:with)

          flat  = request.dup
          route = flat.delete(:to)
          route = take_legacy_route(flat, receiver, legacy_receiver) if route.nil?
          [route, flat]
        end
        private_class_method :split

        def split_envelope(request)
          loose = request.keys - [:to, :with]
          unless loose.empty?
            raise Runtime::TypeMismatch,
                  "an explicit command envelope takes routing in to: and facts in with:, not loose #{loose.sort.join(", ")}"
          end

          facts = request[:with]
          raise Runtime::TypeMismatch, "with: must be a hash of command facts" unless facts.is_a?(Hash)

          [request[:to], facts]
        end
        private_class_method :split_envelope

        def take_legacy_route(flat, receiver, legacy_receiver)
          return unless legacy_receiver

          return flat.delete(legacy_receiver.to_sym) if receiver == :aggregate

          return unless receiver == :entity && legacy_receiver.is_a?(Hash)

          aggregate_key = legacy_receiver.fetch(:aggregate).to_sym
          entity_key    = legacy_receiver.fetch(:entity).to_sym
          return unless flat.key?(aggregate_key) || flat.key?(entity_key)

          { aggregate: flat.delete(aggregate_key), entity: flat.delete(entity_key) }
        end
        private_class_method :take_legacy_route

        # One self-contained check per closed receiver kind, plus a backstop.
        def validate_route!(route, receiver)
          case receiver
          when nil then refuse_receiver(route)
          when :aggregate then require_identity(route)
          when :entity then require_entity_route(route)
          else raise ArgumentError, "unknown receiver kind #{receiver.inspect}"
          end
        end
        private_class_method :validate_route!

        def refuse_receiver(route)
          raise Runtime::TypeMismatch, "this command does not take a receiver in to:" unless route.nil?
        end
        private_class_method :refuse_receiver

        def require_identity(route)
          return unless route.nil? || route.to_s.empty? || route.is_a?(Hash)

          raise Runtime::TypeMismatch, "to: must name the receiving aggregate identity"
        end
        private_class_method :require_identity

        def require_entity_route(route)
          raise Runtime::TypeMismatch, "to: for an entity command must contain aggregate: and entity:" unless route.is_a?(Hash)

          extra = route.keys - [:aggregate, :entity]
          missing = [:aggregate, :entity].select { |key| route[key].nil? || route[key].to_s.empty? }
          return if extra.empty? && missing.empty?

          raise Runtime::TypeMismatch, "to: for an entity command must contain only aggregate: and entity:"
        end
        private_class_method :require_entity_route

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
end
