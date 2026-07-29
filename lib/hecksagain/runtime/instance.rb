module Hecksagain
  module Runtime
    class Instance
      attr_reader :aggregate, :id
      attr_accessor :state

      def initialize(aggregate:, id:, state: nil)
        @aggregate = aggregate
        @id        = id
        @state     = state ? Value.hydrate(aggregate, state) : self.class.defaults(aggregate)
        materialize_identity!
      end

      def self.defaults(aggregate)
        state = aggregate.attributes.each_with_object({}) do |attr, acc|
          acc[attr.name] = attr.list? ? [] : default_for(aggregate, attr)
        end
        state[aggregate.lifecycle.field.to_sym] = aggregate.lifecycle.default if aggregate.lifecycle
        state
      end

      def self.default_for(aggregate, attribute)
        return Value.for_attribute(aggregate, attribute, attribute.default) unless attribute.default.nil?

        value_object = aggregate.value_object(attribute.type)
        return nil unless value_object && value_object.attributes.all? { |field| !field.default.nil? }

        Value.build(value_object, {})
      end

      def [](name) = @state[name.to_sym]

      def key?(name) = @state.key?(name.to_sym)

      def []=(name, value)
        @state[name.to_sym] = value
      end

      def method_missing(name, *args)
        return @state[name] if @state.key?(name)

        super
      end

      def respond_to_missing?(name, include_private = false)
        @state.key?(name) || super
      end

      def to_h = { id: @id }.merge(@state)

      def inspect
        fields = @state.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
        "#<#{@aggregate.name} #{@id} #{fields}>"
      end

      private

      def materialize_identity!
        identity  = @aggregate.identified_by || :id
        attribute = @aggregate.attribute(identity)
        return unless attribute && @state[identity].nil?

        @state[identity] = Value.from_identifier(@aggregate, attribute, @id)
      end
    end
  end
end
