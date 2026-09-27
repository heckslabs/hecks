module Hecks
  # Declares what a construct emits as IR, so its shape is data rather than a hand-written `to_h`.
  #
  #   emits_ir(
  #     name:           :name,                    # send it
  #     attributes:     many(:attributes),        # map(&:to_h)
  #     lifecycle:      one(:lifecycle),          # &.to_h, nil-safe
  #     canonical_form: -> { CanonicalForm.table }  # instance_exec'd
  #   )
  #
  # Key order is declaration order; spec/golden/ir/*.json pins the emitted form.
  module IR
    # Instance-shaped constructs (`Aggregate`, `Policy`) `include Hecks::IR`; class-shaped ones
    # (`Command`, `Entity`, `ValueObject`, which are named as types) `extend` it.
    #
    # Wires an instance-shaped construct's declaration and emission sides in.
    def self.included(base)
      base.extend(Declares)
      base.include(Emits)
    end

    # Wires a class-shaped construct's declaration and emission sides in.
    def self.extended(base)
      base.extend(Declares)
      base.extend(Emits)
    end

    # A field that holds a list of constructs, each emitting itself.
    Many = Struct.new(:source)
    # A field that holds one construct, or nil.
    One  = Struct.new(:source)

    # The declaration side: `emits_ir`, `many`, `one`, and `ir_spec` to read the shape back.
    module Declares
      # Records this construct's field -> emission-rule map.
      #
      # @param spec [Hash{Symbol => Symbol, Many, One, Proc}] each emitted key,
      #   mapped to how it is produced: a Symbol is sent to the construct, `many`/
      #   `one` recurse into nested constructs, and a Proc is instance-`exec`'d
      # @return [void]
      def emits_ir(**spec)
        @ir_spec = spec
      end

      # Marks a field as a list of nested constructs, each emitting itself.
      #
      # @param source [Symbol] the method that returns the list
      # @return [Many] the wrapped source, for `emits_ir`
      def many(source) = Many.new(source)

      # Marks a field as one nested construct, or nothing.
      #
      # @param source [Symbol] the method that returns the construct, or nil
      # @return [One] the wrapped source, for `emits_ir`
      def one(source)  = One.new(source)

      # Walks the superclass chain so a `Class.new(ValueObject)` inherits its base's shape.
      #
      # @return [Hash{Symbol => Symbol, Many, One, Proc}, nil] the declared field -> rule map
      def ir_spec
        return @ir_spec if defined?(@ir_spec) && @ir_spec

        superclass.ir_spec if respond_to?(:superclass) && superclass.respond_to?(:ir_spec)
      end
    end

    # Emits the Hash a construct's `emits_ir` declaration describes, in declaration order.
    module Emits
      def to_h
        spec = ir_spec_for(self)
        raise Undeclared, "#{self} emits IR but never declared its shape with emits_ir" unless spec

        spec.to_h { |key, rule| [key, emit(rule)] }
      end

      private

      def ir_spec_for(construct)
        return construct.ir_spec if construct.respond_to?(:ir_spec)

        construct.class.ir_spec
      end

      def emit(rule)
        case rule
        when Many   then public_send(rule.source).map(&:to_h)
        when One    then public_send(rule.source)&.to_h
        when Symbol then public_send(rule)
        when Proc   then instance_exec(&rule)
        else raise Undeclared, "#{rule.inspect} is not a way to emit a field"
        end
      end
    end

    class Undeclared < StandardError; end
  end
end
