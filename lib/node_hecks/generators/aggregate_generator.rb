# NodeHecks::AggregateGenerator
#
# Generates a TypeScript interface for an aggregate root. Maps domain
# IR attributes to TypeScript types using the TypeContract registry.
#
#   gen = AggregateGenerator.new(aggregate)
#   gen.generate  # => TypeScript source string
#
module NodeHecks
  class AggregateGenerator
    include NodeUtils

    def initialize(aggregate)
      @agg = aggregate
      @user_attrs = @agg.attributes.reject { |a| Hecks::Utils::RESERVED_AGGREGATE_ATTRS.include?(a.name.to_s) }
    end

    def generate
      fields = ["id: string;"]
      @user_attrs.each do |attr|
        fields << "#{NodeUtils.camel_case(attr.name)}: #{NodeUtils.ts_type(attr)};"
      end
      fields << "createdAt: string;"
      fields << "updatedAt: string;"
      NodeUtils.join_lines(NodeUtils.ts_interface(@agg.name, fields))
    end
  end
end
