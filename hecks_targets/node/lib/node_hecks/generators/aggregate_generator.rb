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
      lines = []
      lines << "export interface #{@agg.name} {"
      lines << "  id: string;"
      @user_attrs.each do |attr|
        lines << "  #{NodeUtils.camel_case(attr.name)}: #{NodeUtils.ts_type(attr)};"
      end
      lines << "  createdAt: string;"
      lines << "  updatedAt: string;"
      lines << "}"
      lines.join("\n") + "\n"
    end
  end
end
