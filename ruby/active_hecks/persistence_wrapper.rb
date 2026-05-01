# ActiveHecks::PersistenceWrapper
#
# Wraps save/destroy with ActiveModel validation checks and lifecycle
# callbacks. Adds save! that raises ActiveModel::ValidationError.
#
# Called by ActiveHecks.extend_aggregate during activation.
#
#   pizza.save    # => false if invalid
#   pizza.save!   # => raises ActiveModel::ValidationError if invalid
#   pizza.destroy # => runs :destroy callbacks
#
module ActiveHecks
  module PersistenceWrapper
    def self.bind(klass)
      return unless klass.method_defined?(:save)

      wrap_save(klass)
      wrap_destroy(klass)
    end

    def self.wrap_save(klass)
      original_save = klass.instance_method(:save)

      klass.define_method(:save) do
        return false unless valid?
        run_callbacks(:save) { original_save.bind_call(self) }
      end

      klass.define_method(:save!) do
        raise ActiveModel::ValidationError, self unless valid?
        run_callbacks(:save) { original_save.bind_call(self) }
      end
    end

    def self.wrap_destroy(klass)
      original_destroy = klass.instance_method(:destroy)

      klass.define_method(:destroy) do
        run_callbacks(:destroy) { original_destroy.bind_call(self) }
      end
    end

    private_class_method :wrap_save, :wrap_destroy
  end
end
