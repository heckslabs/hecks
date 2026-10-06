module Hecks
  module Projections
    module Deploy
      module Fargate
        module Cdn
          # The lines of a rendered distribution. Extended onto `Cdn`.
          module Lines
            # Renders one cache behaviour: the default one under `key`, or a list item led by its
            # path.
            #
            # @param key [String, nil] `"DefaultCacheBehavior"`, or nil for a `CacheBehaviors` item
            # @param entry [Hash{Symbol => Object}] the behaviour as `normalize` checks it
            #   (`:origin`,
            #   `:path` for an item, `:viewer_protocol`, `:methods`, `:compress`, `:cache_policy`,
            #   `:origin_request_policy`), and optionally `:response_headers_policy`, each policy as
            #   `[id_or_intrinsic, comment_or_nil]`
            # @param base [String] the indentation of `key`, or of the list item's dash
            # @return [Array<String>] the lines
            def behavior_lines(key, entry, base)
              pad = "#{base}  "
              head = key ? "#{base}#{key}:" : "#{base}- PathPattern: #{Yaml.string(entry[:path])}"
              [head, "#{pad}TargetOriginId: #{entry[:origin]}", *behavior_property_lines(entry, pad)]
            end

            private

            def distribution_head(options, distribution_id)
              lines = ["#{distribution_id}:", "  Type: AWS::CloudFront::Distribution"]
              lines.push("  DeletionPolicy: Retain", "  UpdateReplacePolicy: Retain") if options[:retain]
              lines.push("  Properties:", "    DistributionConfig:", "      Enabled: true", "      HttpVersion: http2")
            end

            def behavior_section(options)
              lines = behavior_lines("DefaultCacheBehavior", options[:default_behavior], "      ")
              lines << "      CacheBehaviors:" unless options[:behaviors].empty?
              options[:behaviors].each { |entry| lines.concat(behavior_lines(nil, entry, "        ")) }
              lines
            end

            def alias_lines(options)
              return [] if options[:aliases].empty?

              ["      Aliases:"] + options[:aliases].map { |name| "        - #{name}" }
            end

            def certificate_lines(options)
              return ["      ViewerCertificate:", "        CloudFrontDefaultCertificate: true"] unless options[:certificate_arn]

              ["      ViewerCertificate:", "        AcmCertificateArn: #{options[:certificate_arn]}",
               "        SslSupportMethod: sni-only", "        MinimumProtocolVersion: #{options[:minimum_protocol]}"]
            end

            def origin_lines(options, alb_id)
              ["      Origins:"] + alb_origin_lines(options, alb_id) + options[:extra_origins].flat_map do |origin|
                s3_origin_lines(origin)
              end
            end

            def alb_origin_lines(options, alb_id)
              lines = ["        - Id: #{options[:origin_id]}", "          DomainName: !GetAtt #{alb_id}.DNSName"]
              lines.concat(origin_header_lines(options[:origin_secret]))
              lines << "          CustomOriginConfig:"
              lines << "            OriginProtocolPolicy: http-only"
              lines.push("            HTTPPort: 80", "            HTTPSPort: 443") if options[:explicit_origin_ports]
              unless options[:origin_ssl_protocols].empty?
                lines << "            OriginSSLProtocols: #{Yaml.flow_list(options[:origin_ssl_protocols])}"
              end
              lines
            end

            def origin_header_lines(secret)
              return [] unless secret

              ["          OriginCustomHeaders:", "            - HeaderName: #{secret[:header]}",
               "              HeaderValue: !Ref #{secret[:parameter]}"]
            end

            def s3_origin_lines(origin)
              lines = ["        - Id: #{origin[:id]}", "          DomainName: #{Yaml.string(origin[:domain_name])}"]
              if origin[:origin_access_control_id]
                lines << "          OriginAccessControlId: #{Yaml.string(origin[:origin_access_control_id])}"
              end
              lines << "          S3OriginConfig: { OriginAccessIdentity: \"\" }"
              lines
            end

            def behavior_property_lines(entry, pad)
              lines = ["#{pad}ViewerProtocolPolicy: #{entry[:viewer_protocol]}",
                       "#{pad}AllowedMethods: #{Yaml.flow_list(entry[:methods])}",
                       "#{pad}CachedMethods: [GET, HEAD]"]
              lines << "#{pad}Compress: #{entry[:compress]}" if entry.key?(:compress)
              lines << policy_line(pad, "CachePolicyId", entry[:cache_policy])
              lines.concat(optional_policy_lines(entry, pad))
            end

            def optional_policy_lines(entry, pad)
              { "OriginRequestPolicyId"   => entry[:origin_request_policy],
                "ResponseHeadersPolicyId" => entry[:response_headers_policy] }
                .select { |_key, policy| policy }
                .map { |key, policy| policy_line(pad, key, policy) }
            end

            def policy_line(pad, key, policy)
              id, label = policy
              label ? "#{pad}#{key}: #{id} # #{label}" : "#{pad}#{key}: #{id}"
            end
          end
        end
      end
    end
  end
end
