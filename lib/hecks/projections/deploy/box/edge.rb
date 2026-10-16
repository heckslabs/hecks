module Hecks
  module Projections
    module Deploy
      module Box
        # The CloudFront edge of a box deploy, for a world that declares `cdn`: the `edge.yaml`
        # stack, the `edge.mk` that deploys it, and the two pieces `make stacks` gains so the box
        # admits the CDN's addresses. Mixed into `Box`, which supplies `template`.
        module Edge
          # The AWS-managed prefix list of CloudFront's origin-facing addresses. Its id differs in
          # every region, so it is looked up by this name rather than written down.
          PREFIX_LIST_NAME = "com.amazonaws.global.cloudfront.origin-facing".freeze

          # @param plan [Settings::Plan] the resolved settings
          # @param region [String] the validated region
          # @return [Hash{String => String}] `edge.yaml` and `edge.mk`, or nothing without a `cdn`
          def edge_files(plan, region)
            return {} unless plan.cdn

            { "edge.yaml" => edge_yaml(plan),
              "edge.mk"   => template("edge.mk.tmpl", "EDGE_STACK" => plan.edge_stack, "REGION" => region) }
          end

          # @param plan [Settings::Plan] the resolved settings, with a `cdn`
          # @return [String] the CloudFront stack
          def edge_yaml(plan)
            values = { "STACK" => plan.infra_name, "ALIASES" => plan.cdn.aliases.join(","),
                       "ORIGIN_HEADER" => plan.origin_header, "ORIGIN_SECRET" => plan.origin_secret }
            template("edge.yaml.tmpl", values)
          end

          # @param plan [Settings::Plan] the resolved settings
          # @param region [String] the validated region
          # @return [Hash{String => String}] the Makefile markers `CDN_CHECK` and `CDN_PARAM`:
          #   empty without a `cdn`, so a world that does not opt in renders the same Makefile
          def edge_makefile_values(plan, region)
            return { "CDN_CHECK" => "", "CDN_PARAM" => "" } unless plan.cdn

            { "CDN_CHECK" => prefix_list_check(region), "CDN_PARAM" => "\t\tCdnPrefixListId=#{prefix_list_lookup(region)} \\" }
          end

          private

          def prefix_list_query(region)
            "aws ec2 describe-managed-prefix-lists --region #{region} --filters " \
              "Name=prefix-list-name,Values=#{PREFIX_LIST_NAME} --query \"PrefixLists[0].PrefixListId\" --output text"
          end

          def prefix_list_lookup(region)
            "$$(#{prefix_list_query(region)})"
          end

          # Stops `make stacks` before it changes anything when the prefix list cannot be found,
          # because a box deployed without it has no inbound rule and the CDN gets a 504.
          def prefix_list_check(region)
            "\t@#{prefix_list_query(region)} | grep -q '^pl-' || { echo \"no #{PREFIX_LIST_NAME} " \
              "prefix list in #{region}: the box would admit no CDN and answer 504\" >&2; exit 1; }"
          end
        end
      end
    end
  end
end
