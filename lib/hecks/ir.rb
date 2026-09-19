module Hecks
  # What a construct emits, declared rather than written out.
  #
  # `IR` is a thing this framework produces, not a thing its model is.
  # The language self-hosts, and its own bluebook declares aggregates
  # named `Bluebook`, `Aggregate`, `Command`, `Entity`, `ValueObject`,
  # `Policy`, `ReadModel` — there is no `IR` aggregate anywhere in the
  # grammar. Where the grammar's own vision line does say IR it means the
  # emission: "the IR it stores must equal the IR the DSL builder
  # produces". `IR_VERSION` says the same thing structurally — a version
  # stamped on `to_h`'s output rather than on the object is a version of
  # the emission, which only makes sense if the two are different things.
  #
  # So emitting IR is a capability a construct has, and this is that
  # capability: `include Hecks::IR` and declare the shape once.
  # The model it emits from is `Hecks::Bluebook` — a chapter class
  # nesting everything a chapter declares. It is deliberately not named
  # after this, its own output.
  #
  # ## Why declared, not hand-written
  #
  # A hand-written `to_h` per construct would say the same four things in the
  # same order — read a field, recurse into a child, recurse into a list, or
  # compute something — leaving a construct's shape knowable only by reading a
  # method body. Declared, it is data: `ir_spec` can be walked by anything
  # that wants to know what a construct carries, which is the whole point of
  # hanging emission off the model rather than burying it.
  #
  # ## Usage
  #
  #   include Hecks::IR            # an instance-shaped construct
  #
  #   emits_ir(
  #     name:           :name,                   # send it
  #     identified_by:  :identity_paths,         # ...under a different key
  #     list:           :list?,                  # ...predicates are fine
  #     attributes:     many(:attributes),       # map(&:to_h)
  #     lifecycle:      one(:lifecycle),         # &.to_h, nil-safe
  #     canonical_form: -> { CanonicalForm.table } # anything else
  #   )
  #
  # Key order is the declaration order, and that is load-bearing rather
  # than cosmetic: `spec/golden/ir/*.json` pins the emitted form exactly,
  # so a reordered declaration is a changed artifact and the golden specs
  # will say so.
  module IR
    # The two shapes a construct comes in, and why this module has two
    # doors instead of hiding the difference.
    #
    # `Bluebook`/`Aggregate`/`Policy`/`ReadModel` are ordinary objects —
    # metadata records, one instance per declaration. `Command`/`Entity`/
    # `ValueObject` are anonymous classes (`Class.new(self)`, see
    # `Command.declare`), because those three are referenced as types in
    # a bluebook (`attribute :price, Money`) and a type has to be a real
    # Ruby constant to be named.
    #
    # That split is real and not worth papering over, so:
    #
    #   include Hecks::IR   # instance-shaped — to_h is an instance method
    #   extend  Hecks::IR   # class-shaped    — to_h is a class method
    #
    # Both get the same `emits_ir` and the same emission rules.
    #
    # Wires an instance-shaped construct's declaration and emission sides in.
    #
    # @param base [Class, Module] the includer
    # @return [void]
    def self.included(base)
      base.extend(Declares)
      base.include(Emits)
    end

    # Wires a class-shaped construct's declaration and emission sides in.
    #
    # @param base [Class, Module] the extender
    # @return [void]
    def self.extended(base)
      base.extend(Declares)
      base.extend(Emits)
    end

    # A field that holds a list of constructs — each one emits itself.
    Many = Struct.new(:source)
    # A field that holds one construct, or nothing. `&.to_h`, never a
    # crash on an undeclared lifecycle.
    One  = Struct.new(:source)

    # The declaration side: `emits_ir(**spec)` records a construct's field ->
    # rule map, `many`/`one` wrap a source name so a field can recurse into a
    # list or a single nested construct, and `ir_spec` reads the declaration
    # back — walking the superclass chain so an anonymous `Class.new(base)`
    # inherits its base's shape instead of redeclaring it.
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

      # Walks the superclass chain so a `Class.new(ValueObject)` — which
      # is what every declared value object actually is — inherits the
      # shape its base declared, rather than each anonymous subclass
      # having to redeclare it.
      #
      # @return [Hash{Symbol => Symbol, Many, One, Proc}, nil] the field -> rule
      #   map declared by `emits_ir`, inherited from the nearest superclass that
      #   declared one; nil if nothing in the chain ever declared a shape
      def ir_spec
        return @ir_spec if defined?(@ir_spec) && @ir_spec

        superclass.ir_spec if respond_to?(:superclass) && superclass.respond_to?(:ir_spec)
      end
    end

    # The emission side: `to_h` reads the declaring construct's `ir_spec` and
    # applies each field's rule (`Many#to_h`, `One&.to_h`, a plain Symbol
    # send, or an instance-`exec`'d Proc) in declaration order to build the
    # actual Hash.
    module Emits
      def to_h
        spec = ir_spec_for(self)
        raise Undeclared, "#{self} emits IR but never declared its shape with emits_ir" unless spec

        spec.to_h { |key, rule| [key, emit(rule)] }
      end

      private

      # An instance reads its class's declaration; a class-shaped
      # construct is the declaration holder.
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
