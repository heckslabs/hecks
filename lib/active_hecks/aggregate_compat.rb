# ActiveHecks::AggregateCompat
#
# Aggregate-specific ActiveModel mixin: identity, validations, and lifecycle
# callbacks. Validations live here (not DomainModelCompat) because value
# objects are frozen and cannot mutate the @errors ivar.
#
# Included by ActiveHecks.extend_aggregate.
#
#   pizza.persisted?       # => true
#   pizza.valid?           # => false
#   pizza.errors[:name]    # => ["can't be blank"]
#   Pizza.before_save { ... }
#
module ActiveHecks
  module AggregateCompat
    def self.included(base)
      base.include(ActiveModel::Validations)
      base.extend(ActiveModel::Callbacks)
      base.define_model_callbacks :save, :create, :update, :destroy
    end

    def to_param
      id
    end

    def to_key
      persisted? ? [id] : nil
    end

    def persisted?
      !id.nil?
    end

    def new_record?
      !persisted?
    end

    def destroyed?
      !!@__destroyed__
    end
  end
end
