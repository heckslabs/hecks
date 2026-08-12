module Hecksagain
  # WHAT A CONSTRUCT EMITS, DECLARED RATHER THAN WRITTEN OUT.
  #
  # `IR` is a thing this framework PRODUCES, not a thing its model IS.
  # The language self-hosts, and its own bluebook declares aggregates
  # named `Bluebook`, `Aggregate`, `Command`, `Entity`, `ValueObject`,
  # `Policy`, `ReadModel` — there is no `IR` aggregate anywhere in the
  # grammar. Where the grammar's own vision line does say IR it means the
  # emission: "the IR it STORES must equal the IR the DSL builder
  # PRODUCES". `IR_VERSION` says the same thing structurally — a version
  # stamped on `to_h`'s output rather than on the object is a version of
  # the EMISSION, which only makes sense if the two are different things.
  #
  # So emitting IR is a CAPABILITY a construct has, and this is that
  # capability: `include Hecksagain::IR` and declare the shape once.
  # (The model still lives under `Bluebook::IR::*`, named after this one
  # output of it. Correcting that is a mechanical rename, deliberately
  # left as its own change so this one stays reviewable.)
  #
  # Before this, eighteen constructs each hand-wrote a `to_h` that said
  # the same four things in the same order — read a field, recurse into a
  # child, recurse into a list, or compute something — and the shape of a
  # construct was knowable only by reading a method body. Declared, it is
  # data: `ir_spec` can be walked by anything that wants to know what a
  # construct carries, which is the whole point of hanging emission off
  # the model rather than burying it.
  #
  #   include Hecksagain::IR            # an instance-shaped construct
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
  # KEY ORDER IS THE DECLARATION ORDER, and that is load-bearing rather
  # than cosmetic: `spec/golden/ir/*.json` pins the emitted form exactly,
  # so a reordered declaration is a changed artifact and the golden specs
  # will say so.
  module IR
    # THE TWO SHAPES A CONSTRUCT COMES IN, and why this module has two
    # doors instead of hiding the difference.
    #
    # `Bluebook`/`Aggregate`/`Policy`/`ReadModel` are ordinary objects —
    # metadata records, one instance per declaration. `Command`/`Entity`/
    # `ValueObject` are anonymous CLASSES (`Class.new(self)`, see
    # `Command.declare`), because those three are referenced as TYPES in
    # a bluebook (`attribute :price, Money`) and a type has to be a real
    # Ruby constant to be named.
    #
    # That split is real and not worth papering over, so:
    #
    #   include Hecksagain::IR   # instance-shaped — to_h is an instance method
    #   extend  Hecksagain::IR   # class-shaped    — to_h is a class method
    #
    # Both get the same `emits_ir` and the same emission rules.
    def self.included(base)
      base.extend(Declares)
      base.include(Emits)
    end

    def self.extended(base)
      base.extend(Declares)
      base.extend(Emits)
    end

    # A field that holds a list of constructs — each one emits itself.
    Many = Struct.new(:source)
    # A field that holds one construct, or nothing. `&.to_h`, never a
    # crash on an undeclared lifecycle.
    One  = Struct.new(:source)

    module Declares
      def emits_ir(**spec)
        @ir_spec = spec
      end

      def many(source) = Many.new(source)
      def one(source)  = One.new(source)

      # Walks the superclass chain so a `Class.new(ValueObject)` — which
      # is what every declared value object actually IS — inherits the
      # shape its base declared, rather than each anonymous subclass
      # having to redeclare it.
      def ir_spec
        return @ir_spec if defined?(@ir_spec) && @ir_spec

        superclass.ir_spec if respond_to?(:superclass) && superclass.respond_to?(:ir_spec)
      end
    end

    module Emits
      def to_h
        spec = ir_spec_for(self)
        raise Undeclared, "#{self} emits IR but never declared its shape with emits_ir" unless spec

        spec.to_h { |key, rule| [key, emit(rule)] }
      end

      private

      # An instance reads its class's declaration; a class-shaped
      # construct IS the declaration holder.
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
