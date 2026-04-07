# ActiveHecks::ValueObjectCompat
#
# Value object-specific ActiveModel mixin: no identity, immutable, no
# validations (frozen objects cannot mutate @errors).
#
# Included by ActiveHecks.extend_value_object.
#
#   topping.persisted?     # => false
#   topping.to_param       # => nil
#
module ActiveHecks
  module ValueObjectCompat
    def to_param
      nil
    end

    def to_key
      nil
    end

    def persisted?
      false
    end

    def new_record?
      true
    end

    def destroyed?
      false
    end
  end
end
