require_relative "../text_template"

module Hecks
  module Projections
    module Deploy
      module Lambda
        # The CloudFront, WAFv2 and logging resources a pii-marked domain is fronted by.
        module Pii
          module_function

          # Builds the resources. `use_oac` signs requests only for the AWS_IAM case; the
          # already-public WebFunction/rust_web Function URL stays as reachable as before. Managed
          # cache/origin-request policy ids are AWS's own permanent `Managed-CachingDisabled`/
          # `Managed-AllViewer` ids.
          #
          # @param fronted_logical_id [String] the function the distribution fronts
          # @param use_oac [Boolean] whether the distribution signs its requests to the function
          # @param geo_restriction_type [String] `none`, `whitelist` or `blacklist`
          # @param geo_restriction_countries [Array<String>] the country codes the restriction lists
          # @return [String] the resources, indented two spaces under `Resources:`
          def cloudfront_yaml(fronted_logical_id:, use_oac:, geo_restriction_type:, geo_restriction_countries:)
            text = TextTemplate.render(
              "lambda/pii_resources.tmpl",
              fronted_logical_id: fronted_logical_id, geo_restriction_type: geo_restriction_type,
              geo_locations: geo_locations(geo_restriction_type, geo_restriction_countries),
              oac_reference: use_oac ? "          OriginAccessControlId: !Ref PiiOriginAccessControl" : "",
              origin_access_control: use_oac ? TextTemplate.render("lambda/pii_oac.tmpl") : "",
              invoke_permission: invoke_permission(fronted_logical_id, use_oac)
            )
            text.each_line.map { |line| line.strip.empty? ? line : "  #{line}" }.join
          end

          def geo_locations(type, countries)
            return " []" if type == "none"

            "\n#{countries.map { |code| "              - #{code}" }.join("\n")}"
          end
          private_class_method :geo_locations

          def invoke_permission(fronted_logical_id, use_oac)
            auth_type = use_oac ? "AWS_IAM" : "NONE"
            TextTemplate.render("lambda/pii_permission.tmpl", fronted_logical_id: fronted_logical_id, invoke_auth_type: auth_type)
          end
          private_class_method :invoke_permission
        end
      end
    end
  end
end
