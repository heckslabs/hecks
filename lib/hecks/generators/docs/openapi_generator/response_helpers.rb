module Hecks
  module HTTP
    class OpenapiGenerator
      # Hecks::HTTP::OpenapiGenerator::ResponseHelpers
      #
      # Shared OpenAPI response/parameter helpers used by both PathBuilder
      # and SchemaBuilder. Provides ok_array, ok_object, ok_message,
      # id_param, and request_body builders.
      #
      # Mixed into OpenapiGenerator for use across all builder modules.
      #
      module ResponseHelpers
        private

        # Builds an OpenAPI +requestBody+ object from a command's attributes.
        # Each attribute becomes a property in the JSON schema.
        #
        # @param cmd [Hecks::DomainModel::Behavior::Command] the command
        # @return [Hash] an OpenAPI requestBody object with JSON content type
        def request_body(cmd)
          props = {}
          cmd.attributes.each do |attr|
            props[attr.name] = { type: openapi_type(attr) }
          end
          { content: { "application/json" => { schema: { type: "object", properties: props } } } }
        end

        # Returns a reusable OpenAPI path parameter definition for +{id}+.
        #
        # @return [Hash] an OpenAPI parameter object for the +id+ path parameter
        def id_param
          { name: "id", in: "path", required: true, schema: { type: "string" } }
        end

        # Builds a 200 response containing a JSON array of the named schema.
        #
        # @param name [String] the schema name to reference (e.g. +"Pizza"+)
        # @return [Hash] an OpenAPI responses object with a 200 array response
        def ok_array(name)
          { "200" => { description: "Array of #{name}s", content: { "application/json" => { schema: { type: "array", items: { "$ref" => "#/components/schemas/#{name}" } } } } } }
        end

        # Builds a 200 response containing a single JSON object of the named schema.
        #
        # @param name [String] the schema name to reference (e.g. +"Pizza"+)
        # @return [Hash] an OpenAPI responses object with a 200 object response
        def ok_object(name)
          { "200" => { description: name, content: { "application/json" => { schema: { "$ref" => "#/components/schemas/#{name}" } } } } }
        end

        # Builds a 200 response with a simple "Success" description and no body.
        #
        # @return [Hash] an OpenAPI responses object with a 200 success response
        def ok_message
          { "200" => { description: "Success" } }
        end
      end
    end
  end
end
