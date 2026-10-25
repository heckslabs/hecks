module Hecks
  module Rails
    # The facts of a command read from a request's parameters: the dotted form names
    # (`balance.cents`) cast to the nested, typed values the command takes, by the same field tree
    # the form was rendered from.
    module Arguments
      module_function

      # @param model [Class] a model class, whose aggregate declares the command
      # @param command [Hecks::Bluebook::Command] the command the parameters are for
      # @param params [ActionController::Parameters, Hash] the request's parameters
      # @return [Hash{Symbol => Object}] the command's facts
      # @raise [Hecks::Refused] when a value cannot be cast, such as text in a number field
      def for(model, command, params)
        aggregate = model.door.ir
        fields = command.attributes.map { |attribute| Hecks::Forms::FieldShape.resolve(attribute, aggregate: aggregate) }
        Hecks::Forms::Params.extract(fields, flat(params))
      rescue ArgumentError, TypeError, JSON::ParserError => e
        raise Hecks::Refused, e.message
      end

      # @return [Hash{String => Object}] the parameters with string keys, nothing filtered: only the
      #   command's own field paths are read from them
      def flat(params)
        (params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h).transform_keys(&:to_s)
      end
    end
  end
end
