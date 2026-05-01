# ActiveHecks::ValidationWiring
#
# Converts DSL validation rules into ActiveModel validates calls and
# replaces the generated validate! (which raises in the constructor)
# with a no-op so invalid objects can be constructed.
#
# Called by ActiveHecks.extend_aggregate during activation.
#
#   # DSL: validation :name, presence: true
#   # becomes: validates :name, presence: true
#
module ActiveHecks
  module ValidationWiring
    # Replace generated validate! with no-op and wire DSL validations.
    def self.bind(klass, domain: nil)
      disable_constructor_validation(klass)
      wire_validations(klass, domain: domain)
    end

    def self.disable_constructor_validation(klass)
      if klass.method_defined?(:validate!) || klass.private_method_defined?(:validate!)
        klass.define_method(:validate!) {}
      end
    end

    def self.wire_validations(klass, domain: nil)
      validations = if klass.respond_to?(:domain_def) && klass.domain_def
        klass.domain_def.validations
      elsif domain
        short_name = klass.name.split("::").last
        agg = domain.aggregates.find { |a| a.name == short_name }
        agg&.validations || []
      end
      return unless validations

      validations.each { |v| klass.validates v.field, v.rules }
    end

    private_class_method :disable_constructor_validation, :wire_validations
  end
end
