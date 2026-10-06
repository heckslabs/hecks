require_relative "check"
require_relative "yaml"
require_relative "cdn_default"
require_relative "cdn/options"
require_relative "cdn/behaviors"
require_relative "cdn/lines"

module Hecks
  module Projections
    module Deploy
      module Fargate
        # The CloudFront distribution in front of the load balancer.
        # With no `cdn` setting the stack gets `default_yaml`; settings are in the DSL reference.
        module Cdn
          MANAGED_POLICIES = {
            "caching_disabled"       => ["4135ea2d-6df8-44a3-9df3-4b5a84be39ad", "Managed-CachingDisabled"],
            "caching_optimized"      => ["658327ea-f89d-4fab-a63d-7e88639e58f6", "Managed-CachingOptimized"],
            "all_viewer"             => ["216adef6-5c7f-47e4-b989-5492eafa07d3", "Managed-AllViewer"],
            "all_viewer_except_host" => ["b689b0a8-53d0-40ab-baf2-68738e2966ac", "Managed-AllViewerExceptHostHeader"]
          }.freeze
          METHODS = {
            "all"      => %w[GET HEAD OPTIONS PUT POST PATCH DELETE],
            "read"     => %w[GET HEAD OPTIONS],
            "get_head" => %w[GET HEAD]
          }.freeze
          PROTOCOLS = %w[allow-all https-only redirect-to-https].freeze
          KEYS = [
            :aliases, :certificate_arn, :minimum_protocol, :origin_id, :origin_ssl_protocols, :explicit_origin_ports,
            :origin_secret, :extra_origins, :default_behavior, :behaviors, :retain
          ].freeze
          BEHAVIOR_KEYS = [:origin, :viewer_protocol, :methods, :compress, :cache_policy, :origin_request_policy].freeze
          UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
          ACM_ARN = %r{\Aarn:aws:acm:us-east-1:\d{12}:certificate/[A-Za-z0-9-]+\z}
          HOSTNAME = /\A(\*\.)?([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}\z/

          extend Options
          extend Behaviors
          extend Lines

          module_function

          # Reads and checks the `cdn` setting.
          def normalize(setting, default_origin_id:)
            return nil if setting.nil?

            given = Check.hash!(setting, "cdn", allowed: KEYS)
            options = base_options(given, default_origin_id)
            options[:extra_origins] = extra_origins(given.fetch(:extra_origins, []))
            origins = origin_ids(options)
            check_unique!(origins, "cdn origin ids")
            with_behaviors(options, given, origins)
          end

          # Lists the template parameters the options need.
          def parameters_yaml(options)
            secret = options && options[:origin_secret]
            return "" unless secret

            <<~PARAMETER
              #{secret[:parameter]}:
                Type: String
                NoEcho: true
                Description: Secret header value CloudFront sends to the origin, so the origin can tell its own traffic.
            PARAMETER
          end

          # Renders the distribution for a set of checked options.
          def yaml(options, distribution_id:, alb_id:)
            lines = distribution_head(options, distribution_id)
            lines.concat(alias_lines(options), certificate_lines(options), origin_lines(options, alb_id),
                         behavior_section(options))
            "#{lines.join("\n")}\n"
          end

          def origin_ids(options)
            [options[:origin_id], *options[:extra_origins].map { |origin| origin[:id] }]
          end
          private_class_method :origin_ids

          def with_behaviors(options, given, origins)
            options[:default_behavior] =
              behavior(given.fetch(:default_behavior, {}), "cdn default_behavior", options, origins, path: false)
            options[:behaviors] = behaviors(given.fetch(:behaviors, []), options, origins)
            options
          end
          private_class_method :with_behaviors
        end
      end
    end
  end
end
