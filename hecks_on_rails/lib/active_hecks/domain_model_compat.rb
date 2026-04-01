# ActiveHecks::DomainModelCompat
#
# Shared ActiveModel compatibility for all domain objects (aggregates + VOs).
# Provides naming, conversion, JSON serialization, and attribute introspection.
#
# Included by ActiveHecks.extend_aggregate and ActiveHecks.extend_value_object.
#
#   pizza.to_model        # => self
#   pizza.as_json          # => {"name" => "Margherita", ...}
#   pizza.attributes       # => {"name" => "Margherita", "id" => "..."}
#
module ActiveHecks
  module DomainModelCompat
    def self.included(base)
      base.extend(ActiveModel::Naming) unless base.respond_to?(:model_name)
      base.include(ActiveModel::Conversion)
      base.include(ActiveModel::Serializers::JSON)
    end

    def to_model
      self
    end

    def attributes
      hash = {}
      hash["id"] = id if respond_to?(:id)
      if self.class.respond_to?(:hecks_attributes)
        self.class.hecks_attributes.each { |a| hash[a.name.to_s] = send(a.name) }
      else
        self.class.instance_method(:initialize).parameters.each do |_, name|
          next unless name
          hash[name.to_s] = send(name) if respond_to?(name)
        end
      end
      %i[created_at updated_at].each do |ts|
        hash[ts.to_s] = send(ts) if respond_to?(ts) && !hash.key?(ts.to_s)
      end
      hash
    end

    def read_attribute_for_serialization(attr)
      send(attr)
    end
  end
end
