module Hecksagain
  # The invisible field a built construct carries.
  #
  # A construct is a Ruby class now — `Pizzas::Pizza`, `Pizzas::Pizza::Price` —
  # so `Class#name` is RUBY's business and answers where the class lives. What a
  # bluebook calls the thing is a different fact, and making `name` carry both
  # means picking which one it does badly: shorten it and two aggregates each
  # declaring `Money` both answer "Money", with `inspect` quietly disagreeing.
  #
  # So the bluebook identity is carried in its own field, under a `hecks_` prefix
  # that no domain attribute can collide with. Invisible means exactly that: not
  # an attribute, not a key in `to_h`, not a reader on instances. Framework
  # metadata about the construct, not part of the domain it describes.
  #
  # The identity is COMPUTED by walking owners rather than stamped, so nothing
  # has to be re-stamped when a chapter is assembled after its aggregates:
  #
  #     Pizzas                     the chapter — no owner
  #     Pizzas::Pizza              an aggregate joins its chapter with ::
  #     Pizzas::Pizza.Price        everything else joins its owner with .
  #
  # That spelling is not invented here. It is the id `MetaValidator::Judge`
  # already mints in `#identify`, so a construct class and the meta-domain's
  # record OF that construct carry the same identity, and there is no
  # translation table between them to be quietly wrong in.
  #
  # Usage:
  #
  #     price = Class.new(IR::ValueObject)
  #     price.hecks_name  = "Price"
  #     price.hecks_owner = pizza_class
  #     price.hecks_fqn                   # => "Pizzas::Pizza.Price"
  module Construct
    # What declares this one — the chapter above an aggregate, the aggregate
    # above a value object. nil for a chapter, which is the top.
    attr_accessor :hecks_owner

    attr_writer :hecks_name

    # The name as the bluebook declares it, never the constant path.
    def hecks_name = @hecks_name

    # How this construct joins its owner. An aggregate is a member of its
    # chapter's namespace (`::`) ; everything else is declared ON its owner
    # (`.`). Overridden by Aggregate, defaulted here for every other construct.
    def hecks_separator = "."

    def hecks_fqn
      return hecks_name.to_s unless hecks_owner

      "#{hecks_owner.hecks_fqn}#{hecks_separator}#{hecks_name}"
    end
  end
end
