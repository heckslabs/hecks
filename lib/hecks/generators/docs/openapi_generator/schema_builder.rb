module Hecks
  module HTTP
    class OpenapiGenerator
      # Hecks::HTTP::OpenapiGenerator::SchemaBuilder
      #
      # Builds OpenAPI component schemas from domain aggregates. Maps DSL
      # attribute types to OpenAPI types (integer, number, object, string).
      #
      # Mixed into OpenapiGenerator to keep schema logic separate from paths.
      #
      module SchemaBuilder
        private

        # Builds OpenAPI component schemas for every aggregate in the domain.
        # Each aggregate becomes an object schema with +id+, its scalar attributes,
        # +created_at+, and +updated_at+. List attributes are excluded from schemas.
        #
        # @return [Hash] a map of schema names to OpenAPI schema objects
        def build_schemas
          schemas = {}
          @domain.aggregates.each do |agg|
            props = { id: { type: "string" } }
            agg.attributes.reject(&:list?).each do |attr|
              props[attr.name] = { type: openapi_type(attr) }
            end
            props[:created_at] = { type: "string", format: "date-time" }
            props[:updated_at] = { type: "string", format: "date-time" }
            schemas[agg.name] = { type: "object", properties: props }
          end
          schemas
        end

        # Maps a domain attribute's Ruby type to an OpenAPI type string.
        #
        # - +Integer+ -> +"integer"+
        # - +Float+ -> +"number"+
        # - +JSON+ -> +"object"+
        # - All others -> +"string"+
        #
        # @param attr [Hecks::DomainModel::Structure::Attribute] the attribute
        # @return [String] the OpenAPI type string
        def openapi_type(attr)
          HecksTemplating::TypeContract.openapi(attr.ruby_type)
        end
      end
    end
  end
end
