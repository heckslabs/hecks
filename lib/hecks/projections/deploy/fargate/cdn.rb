require_relative "check"
require_relative "yaml"
require_relative "cdn_default"

module Hecks
  module Projections
    module Deploy
      module Fargate
        # The CloudFront distribution in front of the load balancer.
        #
        # With no `cdn` setting the stack gets `default_yaml`: the default
        # certificate, one origin, and one behavior that caches nothing. A
        # `cdn` setting replaces that with a distribution described by the
        # world.
        #
        # ## Settings
        #
        # `cdn` is a hash with these optional keys:
        #
        # - `aliases`: hostnames the distribution answers to. Needs `certificate_arn`.
        # - `certificate_arn`: an `ACM` certificate in us-east-1, or an intrinsic such as
        #   `"!Ref CertArn"`.
        # - `minimum_protocol`: the TLS policy for the certificate; `TLSv1.2_2021` by default.
        # - `origin_id`: the id of the load-balancer origin; `<AlbId>Origin` by default.
        # - `origin_ssl_protocols`: the TLS versions CloudFront may use to reach the origin, such
        #   as `["TLSv1.2"]`.
        # - `explicit_origin_ports`: false leaves `HTTPPort` and `HTTPSPort` unset; true by
        #   default.
        # - `origin_secret`: `{header:, parameter:}` sends a secret header to the origin, filled
        #   from a `NoEcho` template parameter the stack declares under that name.
        # - `extra_origins`: S3 origins, each `{id:, domain_name:, origin_access_control_id:}`.
        # - `default_behavior`: `{origin:, viewer_protocol:, methods:, compress:, cache_policy:,
        #   origin_request_policy:}`.
        # - `behaviors`: entries of the same shape with a required `path`; the first match wins,
        #   so order matters.
        # - `retain`: true keeps the distribution when the stack is deleted or replaces it.
        #
        # A cache or origin-request policy is a managed policy's name (`caching_disabled`,
        # `caching_optimized`, `all_viewer`, `all_viewer_except_host`, or `none` to omit an origin
        # request policy) or the id of a policy in the account. `methods` is `all`, `read` or
        # `get_head`.
        module Cdn
          module_function

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

          # Reads and checks the `cdn` setting.
          #
          # @param setting [Hash, nil] the world's `cdn` value, or nil when it sets none
          # @param default_origin_id [String] the load-balancer origin's id when `origin_id` is not
          #   set
          # @return [Hash{Symbol => Object}, nil] the checked options with defaults applied, or nil
          #   for none
          # @raise [ArgumentError] if an option is unknown, malformed, or names an origin that does
          #   not exist
          def normalize(setting, default_origin_id:)
            return nil if setting.nil?

            given = Check.hash!(setting, "cdn", allowed: KEYS)
            options = base_options(given, default_origin_id)
            options[:extra_origins] = extra_origins(given.fetch(:extra_origins, []))
            origins = [options[:origin_id], *options[:extra_origins].map { |origin| origin[:id] }]
            check_unique!(origins, "cdn origin ids")
            options[:default_behavior] =
              behavior(given.fetch(:default_behavior, {}), "cdn default_behavior", options, origins, path: false)
            options[:behaviors] = behaviors(given.fetch(:behaviors, []), options, origins)
            options
          end

          # Lists the template parameters the options need.
          #
          # @param options [Hash, nil] the checked options from `normalize`
          # @return [String] flush-left parameter text, or empty
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
          #
          # @param options [Hash] the checked options from `normalize`
          # @param distribution_id [String] the logical id the distribution is given
          # @param alb_id [String] the logical id of the load balancer the origin points at
          # @return [String] the flush-left resource text ending in a newline
          def yaml(options, distribution_id:, alb_id:)
            lines = ["#{distribution_id}:", "  Type: AWS::CloudFront::Distribution"]
            lines.push("  DeletionPolicy: Retain", "  UpdateReplacePolicy: Retain") if options[:retain]
            lines.push("  Properties:", "    DistributionConfig:", "      Enabled: true", "      HttpVersion: http2")
            lines.concat(alias_lines(options), certificate_lines(options), origin_lines(options, alb_id))
            lines.concat(behavior_lines("DefaultCacheBehavior", options[:default_behavior], "      "))
            lines << "      CacheBehaviors:" unless options[:behaviors].empty?
            options[:behaviors].each { |entry| lines.concat(behavior_lines(nil, entry, "        ")) }
            "#{lines.join("\n")}\n"
          end

          def behaviors(entries, options, origins)
            Check.hashes!(entries, "cdn behaviors", allowed: BEHAVIOR_KEYS + [:path], required: [:path]).map do |entry|
              behavior(entry, "cdn behaviors[#{entry[:path]}]", options, origins, path: true)
            end
          end
          private_class_method :behaviors

          def base_options(given, default_origin_id)
            aliases = Check.strings!(given.fetch(:aliases, []), "cdn aliases")
            bad = aliases.grep_v(HOSTNAME)
            raise ArgumentError, "cdn aliases must be hostnames, got #{bad.join(', ')}" unless bad.empty?

            certificate = given[:certificate_arn]&.to_s
            if !aliases.empty? && certificate.nil?
              raise ArgumentError,
                    "cdn aliases need a certificate_arn, since CloudFront serves an alias only over a certificate"
            end

            {
              aliases: aliases, certificate_arn: certificate_arn(certificate),
              minimum_protocol: given.fetch(:minimum_protocol, "TLSv1.2_2021").to_s,
              origin_id: Check.logical_id!(given.fetch(:origin_id, default_origin_id), "cdn origin_id"),
              origin_ssl_protocols: Check.strings!(given.fetch(:origin_ssl_protocols, []), "cdn origin_ssl_protocols"),
              explicit_origin_ports: Check.boolean!(given.fetch(:explicit_origin_ports, true), "cdn explicit_origin_ports"),
              origin_secret: origin_secret(given[:origin_secret]),
              retain: Check.boolean!(given.fetch(:retain, false), "cdn retain")
            }
          end
          private_class_method :base_options

          def certificate_arn(value)
            return nil if value.nil?
            return value if value.start_with?("!") || ACM_ARN.match?(value)

            raise ArgumentError,
                  "cdn certificate_arn must be an ACM certificate ARN in us-east-1 (CloudFront reads no other region) " \
                  "or an intrinsic, got #{value.inspect}"
          end
          private_class_method :certificate_arn

          def origin_secret(value)
            return nil if value.nil?

            secret = Check.hash!(value, "cdn origin_secret", allowed: [:header, :parameter], required: [:header, :parameter])
            unless secret[:header].to_s.match?(/\A[A-Za-z0-9-]+\z/)
              raise ArgumentError,
                    "cdn origin_secret header must be an HTTP header name, got #{secret[:header].inspect}"
            end

            { header: secret[:header].to_s, parameter: Check.logical_id!(secret[:parameter], "cdn origin_secret parameter") }
          end
          private_class_method :origin_secret

          def extra_origins(entries)
            Check.hashes!(entries, "cdn extra_origins", allowed:  [:id, :domain_name, :origin_access_control_id],
                                                        required: [:id, :domain_name]).map do |entry|
              { id: Check.logical_id!(entry[:id], "cdn extra_origins id"), domain_name: entry[:domain_name].to_s,
                origin_access_control_id: entry[:origin_access_control_id]&.to_s }
            end
          end
          private_class_method :extra_origins

          def check_unique!(values, what)
            repeated = values.tally.select { |_value, count| count > 1 }.keys
            raise ArgumentError, "#{what} must be unique; repeated: #{repeated.join(', ')}" unless repeated.empty?
          end
          private_class_method :check_unique!

          def behavior(entry, where, options, origins, path:)
            given = Check.hash!(entry, where, allowed: BEHAVIOR_KEYS + (path ? [:path] : []))
            origin = given.fetch(:origin, options[:origin_id]).to_s
            unless origins.include?(origin)
              raise ArgumentError,
                    "#{where} origin #{origin.inspect} is not one of #{origins.join(', ')}"
            end

            balanced = origin == options[:origin_id]
            result = {
              origin: origin, methods: allowed_methods(given.fetch(:methods, path ? "read" : "all"), where),
              viewer_protocol: Check.one_of!(given.fetch(:viewer_protocol, "redirect-to-https"), "#{where} viewer_protocol",
                                             PROTOCOLS),
              cache_policy: policy(given.fetch(:cache_policy, "caching_disabled"), "#{where} cache_policy"),
              origin_request_policy: policy(given.fetch(:origin_request_policy, balanced ? "all_viewer" : "none"),
                                            "#{where} origin_request_policy", none: true)
            }
            result[:compress] = Check.boolean!(given[:compress], "#{where} compress") if given.key?(:compress)
            result[:compress] = true if !path && !given.key?(:compress)
            result[:path] = path_pattern(given[:path], where) if path
            result
          end
          private_class_method :behavior

          def path_pattern(value, where)
            text = value.to_s
            raise ArgumentError, "#{where} path must start with / or *, got #{text.inspect}" unless text.start_with?("/", "*")

            text
          end
          private_class_method :path_pattern

          def allowed_methods(value, where)
            return Check.strings!(value, "#{where} methods", min: 1) if value.is_a?(Array)
            return METHODS.fetch(value.to_s) if METHODS.key?(value.to_s)

            raise ArgumentError,
                  "#{where} methods must be #{METHODS.keys.join(', ')} or a list of HTTP methods, got #{value.inspect}"
          end
          private_class_method :allowed_methods

          def policy(value, where, none: false)
            text = value.to_s
            return nil if none && text == "none"
            return MANAGED_POLICIES.fetch(text) if MANAGED_POLICIES.key?(text)
            return [text, nil] if UUID.match?(text)

            raise ArgumentError,
                  "#{where} must be #{MANAGED_POLICIES.keys.join(', ')}#{', none' if none}, or a policy id, got #{value.inspect}"
          end
          private_class_method :policy

          def alias_lines(options)
            return [] if options[:aliases].empty?

            ["      Aliases:"] + options[:aliases].map { |name| "        - #{name}" }
          end
          private_class_method :alias_lines

          def certificate_lines(options)
            return ["      ViewerCertificate:", "        CloudFrontDefaultCertificate: true"] unless options[:certificate_arn]

            ["      ViewerCertificate:", "        AcmCertificateArn: #{options[:certificate_arn]}",
             "        SslSupportMethod: sni-only", "        MinimumProtocolVersion: #{options[:minimum_protocol]}"]
          end
          private_class_method :certificate_lines

          def origin_lines(options, alb_id)
            ["      Origins:"] + alb_origin_lines(options, alb_id) + options[:extra_origins].flat_map do |origin|
              s3_origin_lines(origin)
            end
          end
          private_class_method :origin_lines

          def alb_origin_lines(options, alb_id)
            lines = ["        - Id: #{options[:origin_id]}", "          DomainName: !GetAtt #{alb_id}.DNSName"]
            secret = options[:origin_secret]
            if secret
              lines.push("          OriginCustomHeaders:", "            - HeaderName: #{secret[:header]}",
                         "              HeaderValue: !Ref #{secret[:parameter]}")
            end
            lines << "          CustomOriginConfig:"
            lines << "            OriginProtocolPolicy: http-only"
            lines.push("            HTTPPort: 80", "            HTTPSPort: 443") if options[:explicit_origin_ports]
            unless options[:origin_ssl_protocols].empty?
              lines << "            OriginSSLProtocols: #{Yaml.flow_list(options[:origin_ssl_protocols])}"
            end
            lines
          end
          private_class_method :alb_origin_lines

          def s3_origin_lines(origin)
            lines = ["        - Id: #{origin[:id]}", "          DomainName: #{Yaml.string(origin[:domain_name])}"]
            if origin[:origin_access_control_id]
              lines << "          OriginAccessControlId: #{Yaml.string(origin[:origin_access_control_id])}"
            end
            lines << "          S3OriginConfig: { OriginAccessIdentity: \"\" }"
            lines
          end
          private_class_method :s3_origin_lines

          def behavior_lines(key, entry, base)
            pad = "#{base}  "
            head = key ? "#{base}#{key}:" : "#{base}- PathPattern: #{Yaml.string(entry[:path])}"
            [head, "#{pad}TargetOriginId: #{entry[:origin]}", *behavior_property_lines(entry, pad)]
          end
          private_class_method :behavior_lines

          def behavior_property_lines(entry, pad)
            lines = ["#{pad}ViewerProtocolPolicy: #{entry[:viewer_protocol]}",
                     "#{pad}AllowedMethods: #{Yaml.flow_list(entry[:methods])}",
                     "#{pad}CachedMethods: [GET, HEAD]"]
            lines << "#{pad}Compress: #{entry[:compress]}" if entry.key?(:compress)
            lines << policy_line(pad, "CachePolicyId", entry[:cache_policy])
            lines << policy_line(pad, "OriginRequestPolicyId", entry[:origin_request_policy]) if entry[:origin_request_policy]
            lines
          end
          private_class_method :behavior_property_lines

          def policy_line(pad, key, policy)
            id, label = policy
            label ? "#{pad}#{key}: #{id} # #{label}" : "#{pad}#{key}: #{id}"
          end
          private_class_method :policy_line
        end
      end
    end
  end
end
