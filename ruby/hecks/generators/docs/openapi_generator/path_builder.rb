
module Hecks
  module HTTP
    class OpenapiGenerator
      # Hecks::HTTP::OpenapiGenerator::PathBuilder
      #
      # Builds OpenAPI path entries from domain aggregates. Each aggregate
      # gets CRUD paths and query paths; a shared /events SSE path is added.
      #
      # Mixed into OpenapiGenerator to keep path logic separate from schemas.
      #
      module PathBuilder
        include HecksTemplating::NamingHelpers
        private

        # Builds all OpenAPI path entries for the domain. Iterates over every
        # aggregate to create CRUD paths and query paths, then adds a shared
        # +/events+ SSE endpoint.
        #
        # @return [Hash] a map of URL paths to OpenAPI path item objects
        def build_paths
          paths = {}
          @domain.aggregates.each do |agg|
            slug = bluebook_aggregate_slug(agg.name)
            paths.merge!(crud_paths(agg, slug))
            paths.merge!(query_paths(agg, slug))
          end
          paths["/events"] = events_path
          paths
        end

        # Builds CRUD path entries for a single aggregate: list/create on
        # +/<slug>+ and find/update/delete on +/<slug>/{id}+.
        #
        # @param agg [Hecks::BluebookModel::Structure::Aggregate] the aggregate
        # @param slug [String] the pluralized snake_case URL segment
        # @return [Hash] path entries for the CRUD operations
        def crud_paths(agg, slug)
          name = agg.name
          paths = {}

          paths["/#{slug}"] = {
            get: { summary: "List all #{name}s", responses: ok_array(name) },
            post: post_path(agg, slug)
          }.compact

          paths["/#{slug}/{id}"] = {
            get: { summary: "Find #{name} by ID", parameters: [id_param], responses: ok_object(name) },
            patch: patch_path(agg),
            delete: { summary: "Delete #{name}", parameters: [id_param], responses: ok_message }
          }.compact

          paths
        end

        # Builds the POST operation for creating an aggregate. Returns +nil+ if
        # no command starting with "Create" exists.
        #
        # @param agg [Hecks::BluebookModel::Structure::Aggregate] the aggregate
        # @param slug [String] the pluralized snake_case URL segment (unused but
        #   kept for interface consistency)
        # @return [Hash, nil] the POST operation object, or nil
        def post_path(agg, slug)
          cmd = agg.commands.find { |c| c.name.start_with?("Create") }
          return nil unless cmd
          {
            summary: cmd.name,
            requestBody: request_body(cmd),
            responses: ok_object(agg.name)
          }
        end

        # Builds the PATCH operation for updating an aggregate. Returns +nil+ if
        # no command starting with "Update" exists.
        #
        # @param agg [Hecks::BluebookModel::Structure::Aggregate] the aggregate
        # @return [Hash, nil] the PATCH operation object, or nil
        def patch_path(agg)
          cmd = agg.commands.find { |c| c.name.start_with?("Update") }
          return nil unless cmd
          {
            summary: cmd.name,
            parameters: [id_param],
            requestBody: request_body(cmd),
            responses: ok_object(agg.name)
          }
        end

        # Builds GET path entries for each query defined on the aggregate.
        # Query parameters are derived from the query block's parameter list.
        #
        # @param agg [Hecks::BluebookModel::Structure::Aggregate] the aggregate
        # @param slug [String] the pluralized snake_case URL segment
        # @return [Hash] path entries for query operations
        def query_paths(agg, slug)
          paths = {}
          agg.queries.each do |query|
            qn = bluebook_snake_name(query.name)
            params = query.block.parameters.map do |_, name|
              { name: name.to_s, in: "query", schema: { type: "string" }, required: true }
            end
            paths["/#{slug}/#{qn}"] = {
              get: {
                summary: "#{agg.name}.#{qn}",
                parameters: params.empty? ? nil : params,
                responses: ok_array(agg.name)
              }.compact
            }
          end
          paths
        end

        # Builds the +/events+ SSE (Server-Sent Events) path entry.
        #
        # @return [Hash] the path item object for the events endpoint
        def events_path
          { get: { summary: "SSE event stream", responses: { "200" => { description: "Server-Sent Events stream" } } } }
        end
      end
    end
  end
end
