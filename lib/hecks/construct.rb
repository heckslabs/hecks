module Hecks
  # The invisible identity a built construct carries: an owner chain under `hecks_`-prefixed
  # fields, not an attribute and not a key in `to_h`.
  #
  # The fully-qualified name walks owners and matches the id `MetaValidator::Judge#identify` mints.
  #
  #     Pizzas                     the chapter, no owner
  #     Pizzas::Pizza              an aggregate joins its chapter with ::
  #     Pizzas::Pizza.Price        everything else joins its owner with .
  #     price = Class.new(ValueObject)   # a declaration holder
  #     price.hecks_name  = "Price"
  #     price.hecks_owner = pizza_ir         # the Aggregate that declares it
  #     price.hecks_fqn                      # => "Pizzas::Pizza.Price"
  module Construct
    # A construct asked for an identity it cannot compute.
    class Unowned < StandardError; end

    # What declares this construct; nil for a chapter, which is the top.
    attr_accessor :hecks_owner

    attr_writer :hecks_name

    # Marks a chapter, the only construct that legitimately has no owner.
    attr_writer :hecks_root

    # Whether this construct is the top of its own owner chain.
    #
    # @return [Boolean] true for a chapter, which sets `hecks_root`; false otherwise
    def hecks_root? = @hecks_root ? true : false

    # The name as the bluebook declares it, never the constant path.
    #
    # @return [String] the construct's own name, without any owner prefix
    def hecks_name = @hecks_name

    # How this construct joins its owner: `::` for an aggregate, `.` for everything else.
    #
    # @return [String] `"."`, the separator this construct uses in `hecks_fqn`
    def hecks_separator = "."

    # Refuses rather than answering a bare name for an unstamped construct.
    #
    # @return [String] the fully-qualified name, joining every owner from the
    #   chapter down to this construct
    # @raise [Construct::Unowned] if this construct has no owner and is not itself
    #   a chapter (root)
    def hecks_fqn
      return hecks_name.to_s if hecks_root?

      unless hecks_owner
        raise Construct::Unowned,
              "#{hecks_name.inspect} cannot say what declares it, so it has no " \
              "identity — it was never stamped with an owner"
      end

      "#{hecks_owner.hecks_fqn}#{hecks_separator}#{hecks_name}"
    end
  end
end
