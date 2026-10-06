module Hecks
  module Projections
    module Deploy
      module Fargate
        module Cdn
          # Reads and checks the `cdn` setting into the options `Cdn.yaml` renders. Extended onto
          # `Cdn`, which supplies the constants and `Check`.
          module Options
            private

            def base_options(given, default_origin_id)
              aliases = alias_names(given)
              certificate = given[:certificate_arn]&.to_s
              check_alias_certificate!(aliases, certificate)
              {
                aliases: aliases, certificate_arn: certificate_arn(certificate),
                minimum_protocol: given.fetch(:minimum_protocol, "TLSv1.2_2021").to_s,
                **origin_options(given, default_origin_id),
                retain: Check.boolean!(given.fetch(:retain, false), "cdn retain")
              }
            end

            def alias_names(given)
              aliases = Check.strings!(given.fetch(:aliases, []), "cdn aliases")
              bad = aliases.grep_v(HOSTNAME)
              raise ArgumentError, "cdn aliases must be hostnames, got #{bad.join(", ")}" unless bad.empty?

              aliases
            end

            def check_alias_certificate!(aliases, certificate)
              return unless !aliases.empty? && certificate.nil?

              raise ArgumentError,
                    "cdn aliases need a certificate_arn, since CloudFront serves an alias only over a certificate"
            end

            def origin_options(given, default_origin_id)
              {
                origin_id:             Check.logical_id!(given.fetch(:origin_id, default_origin_id), "cdn origin_id"),
                origin_ssl_protocols:  Check.strings!(given.fetch(:origin_ssl_protocols, []), "cdn origin_ssl_protocols"),
                explicit_origin_ports: Check.boolean!(given.fetch(:explicit_origin_ports, true), "cdn explicit_origin_ports"),
                origin_secret:         origin_secret(given[:origin_secret])
              }
            end

            def certificate_arn(value)
              return nil if value.nil?
              return value if value.start_with?("!") || ACM_ARN.match?(value)

              raise ArgumentError,
                    "cdn certificate_arn must be an ACM certificate ARN in us-east-1 (CloudFront reads no other region) " \
                    "or an intrinsic, got #{value.inspect}"
            end

            def origin_secret(value)
              return nil if value.nil?

              secret = Check.hash!(value, "cdn origin_secret", allowed: [:header, :parameter], required: [:header, :parameter])
              unless secret[:header].to_s.match?(/\A[A-Za-z0-9-]+\z/)
                raise ArgumentError,
                      "cdn origin_secret header must be an HTTP header name, got #{secret[:header].inspect}"
              end

              { header: secret[:header].to_s, parameter: Check.logical_id!(secret[:parameter], "cdn origin_secret parameter") }
            end

            def extra_origins(entries)
              Check.hashes!(entries, "cdn extra_origins", allowed:  [:id, :domain_name, :origin_access_control_id],
                                                          required: [:id, :domain_name]).map do |entry|
                { id: Check.logical_id!(entry[:id], "cdn extra_origins id"), domain_name: entry[:domain_name].to_s,
                  origin_access_control_id: entry[:origin_access_control_id]&.to_s }
              end
            end

            def check_unique!(values, what)
              repeated = values.tally.select { |_value, count| count > 1 }.keys
              raise ArgumentError, "#{what} must be unique; repeated: #{repeated.join(", ")}" unless repeated.empty?
            end
          end
        end
      end
    end
  end
end
