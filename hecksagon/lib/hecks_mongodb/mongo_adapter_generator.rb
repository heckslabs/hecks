# = Hecks::MongoAdapterGenerator
#
# Generates MongoDB repository adapter classes for each aggregate.
# Each adapter wraps a Mongo::Collection and implements the standard
# repository interface: find, save, delete, all, count, query, clear.
#
#   gen = MongoAdapterGenerator.new(agg, domain_module: "PizzasDomain")
#   gen.generate  # => Ruby source string
#
module Hecks
  class MongoAdapterGenerator
    include HecksTemplating::NamingHelpers

    def initialize(aggregate, domain_module:)
      @aggregate = aggregate
      @domain_module = domain_module
      @safe_name = domain_constant_name(@aggregate.name)
    end

    def generate
      snake = domain_snake_name(@safe_name)
      lines = []
      lines << "module #{@domain_module}"
      lines << "  module Adapters"
      lines << "    class #{@safe_name}MongoRepository"
      lines << "      def initialize(collection)"
      lines << "        @collection = collection"
      lines << "      end"
      lines << ""
      lines << "      def find(id)"
      lines << "        doc = @collection.find(_id: id).first"
      lines << "        return nil unless doc"
      lines << "        deserialize(doc)"
      lines << "      end"
      lines << ""
      lines << "      def save(#{snake})"
      lines << "        doc = serialize(#{snake})"
      lines << "        @collection.replace_one({ _id: #{snake}.id }, doc, upsert: true)"
      lines << "        #{snake}"
      lines << "      end"
      lines << ""
      lines << "      def delete(id)"
      lines << "        @collection.delete_one(_id: id)"
      lines << "      end"
      lines << ""
      lines << "      def all"
      lines << "        @collection.find.map { |doc| deserialize(doc) }"
      lines << "      end"
      lines << ""
      lines << "      def count"
      lines << "        @collection.count_documents({})"
      lines << "      end"
      lines << ""
      lines.concat(query_lines(6))
      lines << ""
      lines << "      def clear"
      lines << "        @collection.delete_many({})"
      lines << "      end"
      lines << ""
      lines << "      private"
      lines << ""
      lines.concat(serialize_lines(6))
      lines << ""
      lines.concat(deserialize_lines(6))
      lines << "    end"
      lines << "  end"
      lines << "end"
      lines.join("\n") + "\n"
    end

    private

    def query_lines(indent)
      pad = " " * indent
      [
        "#{pad}def query(conditions: {}, order_key: nil, order_direction: :asc, limit: nil, offset: nil)",
        "#{pad}  filter = {}",
        "#{pad}  conditions.each do |k, v|",
        "#{pad}    if v.respond_to?(:to_mongo_filter)",
        "#{pad}      filter[k.to_s] = v.to_mongo_filter",
        "#{pad}    else",
        "#{pad}      filter[k.to_s] = v",
        "#{pad}    end",
        "#{pad}  end",
        "#{pad}  cursor = @collection.find(filter)",
        "#{pad}  cursor = cursor.sort(order_key.to_s => order_direction == :desc ? -1 : 1) if order_key",
        "#{pad}  cursor = cursor.skip(offset) if offset && offset > 0",
        "#{pad}  cursor = cursor.limit(limit) if limit && limit > 0",
        "#{pad}  cursor.map { |doc| deserialize(doc) }",
        "#{pad}end"
      ]
    end

    def serialize_lines(indent)
      pad = " " * indent
      attrs = @aggregate.attributes.reject(&:list?)
      refs = @aggregate.references || []
      fields = attrs.map { |a| "\"#{a.name}\" => obj.#{a.name}" }
      fields += refs.map { |r| "\"#{r.name}_id\" => obj.respond_to?(:#{r.name}_id) ? obj.#{r.name}_id : nil" }
      [
        "#{pad}def serialize(obj)",
        "#{pad}  {",
        "#{pad}    \"_id\" => obj.id,",
        *fields.map { |f| "#{pad}    #{f}," },
        "#{pad}    \"created_at\" => obj.respond_to?(:created_at) ? obj.created_at&.to_s : nil,",
        "#{pad}    \"updated_at\" => obj.respond_to?(:updated_at) ? obj.updated_at&.to_s : nil",
        "#{pad}  }",
        "#{pad}end"
      ]
    end

    def deserialize_lines(indent)
      pad = " " * indent
      attrs = @aggregate.attributes.reject(&:list?)
      params = attrs.map { |a| "#{a.name}: doc[\"#{a.name}\"]" }
      [
        "#{pad}def deserialize(doc)",
        "#{pad}  klass = #{@domain_module}.const_get(\"#{@safe_name}\")",
        "#{pad}  obj = klass.new(#{params.join(", ")})",
        "#{pad}  obj.instance_variable_set(:@id, doc[\"_id\"]) if doc[\"_id\"]",
        "#{pad}  obj",
        "#{pad}end"
      ]
    end
  end
end
