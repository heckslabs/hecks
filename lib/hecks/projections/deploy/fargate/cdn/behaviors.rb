module Hecks
  module Projections
    module Deploy
      module Fargate
        module Cdn
          # Reads and checks the `default_behavior` and `behaviors` of the `cdn` setting. Extended
          # onto `Cdn`, which supplies the constants and `Check`.
          module Behaviors
            private

            def behaviors(entries, options, origins)
              Check.hashes!(entries, "cdn behaviors", allowed: BEHAVIOR_KEYS + [:path], required: [:path]).map do |entry|
                behavior(entry, "cdn behaviors[#{entry[:path]}]", options, origins, path: true)
              end
            end

            def behavior(entry, where, options, origins, path:)
              given = Check.hash!(entry, where, allowed: BEHAVIOR_KEYS + (path ? [:path] : []))
              origin = given.fetch(:origin, options[:origin_id]).to_s
              unless origins.include?(origin)
                raise ArgumentError,
                      "#{where} origin #{origin.inspect} is not one of #{origins.join(", ")}"
              end

              result = behavior_fields(given, where, origin, origin == options[:origin_id], path)
              add_compress!(result, given, where, path)
              result[:path] = path_pattern(given[:path], where) if path
              result
            end

            def behavior_fields(given, where, origin, balanced, path)
              {
                origin: origin, methods: allowed_methods(given.fetch(:methods, path ? "read" : "all"), where),
                viewer_protocol: Check.one_of!(given.fetch(:viewer_protocol, "redirect-to-https"), "#{where} viewer_protocol",
                                               PROTOCOLS),
                cache_policy: policy(given.fetch(:cache_policy, "caching_disabled"), "#{where} cache_policy"),
                origin_request_policy: policy(given.fetch(:origin_request_policy, balanced ? "all_viewer" : "none"),
                                              "#{where} origin_request_policy", none: true)
              }
            end

            def add_compress!(result, given, where, path)
              result[:compress] = Check.boolean!(given[:compress], "#{where} compress") if given.key?(:compress)
              result[:compress] = true if !path && !given.key?(:compress)
            end

            def path_pattern(value, where)
              text = value.to_s
              raise ArgumentError, "#{where} path must start with / or *, got #{text.inspect}" unless text.start_with?("/", "*")

              text
            end

            def allowed_methods(value, where)
              return Check.strings!(value, "#{where} methods", min: 1) if value.is_a?(Array)
              return METHODS.fetch(value.to_s) if METHODS.key?(value.to_s)

              raise ArgumentError,
                    "#{where} methods must be #{METHODS.keys.join(", ")} or a list of HTTP methods, got #{value.inspect}"
            end

            def policy(value, where, none: false)
              text = value.to_s
              return nil if none && text == "none"
              return MANAGED_POLICIES.fetch(text) if MANAGED_POLICIES.key?(text)
              return [text, nil] if UUID.match?(text)

              raise ArgumentError, "#{where} must be #{MANAGED_POLICIES.keys.join(", ")}#{", none" if none}, " \
                                   "or a policy id, got #{value.inspect}"
            end
          end
        end
      end
    end
  end
end
