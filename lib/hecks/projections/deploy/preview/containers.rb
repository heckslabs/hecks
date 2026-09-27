module Hecks
  module Projections
    module Deploy
      module Preview
        # The containers one preview task runs, normalized via `resolve`; `shared_setting`
        # is the one hook into the main stack's own (still-growing) multi-container setting.
        module Containers
          # One normalized container of the preview task.
          Entry = Data.define(:name, :port, :health_check_path, :paths, :default, :host, :database,
                              :environment, :secrets, :image) do
            # CamelCases `name`, e.g. `"my-site"` becomes `"MySite"`.
            def logical = name.split("-").map(&:capitalize).join

            def routed? = default || !paths.empty?
          end

          NAME_PATTERN = /\A[a-z][a-z0-9-]{0,29}\z/
          PATH_PATTERN = %r{\A/[A-Za-z0-9._~/*?%-]*\z}
          IMAGE_PATTERN = %r{\A[A-Za-z0-9._/:@-]+\z}
          ENV_NAME_PATTERN = /\A[A-Z_][A-Z0-9_]*\z/

          module_function

          # `preview[:containers]` wins over the main stack's own multi-container setting,
          # which wins over a single entry built from the main stack's own container.
          def resolve(preview:, deploy_settings:, main:, signup_path: nil)
            raw = preview[:containers] || shared_setting(deploy_settings) || [single(main)]
            entries = Array(raw).map { |item| normalize(item) }
            check!(entries)
            with_default(with_signup(entries, signup_path))
          end

          def shared_setting(deploy_settings)
            deploy_settings[:containers]
          end

          def single(main)
            name = main.fetch(:name).to_s.downcase.gsub(/[^a-z0-9]+/, "-").sub(/\A[^a-z]+/, "")[0, 30].sub(/-+\z/, "")
            { name: name, port: main.fetch(:port), host: true, default: true, image: main[:image] }
          end

          def normalize(item)
            raise ArgumentError, "preview container #{item.inspect} must be a Hash" unless item.is_a?(Hash)

            item = item.transform_keys(&:to_sym)
            name = matching(item[:name], NAME_PATTERN, "preview container name")
            Entry.new(
              name: name, port: port_of(item, name), health_check_path: path_of(item[:health_check_path] || "/"),
              paths: Array(item[:paths]).map { |path| path_of(path) }, default: item[:default] == true,
              host: item[:host] == true, database: item[:database] == true,
              environment: environment_of(item[:environment]), secrets: Array(item[:secrets]).map(&:to_s),
              image: matching(item[:image] || "#{name}:latest", IMAGE_PATTERN, "preview container #{name} image")
            )
          end

          def matching(value, pattern, label)
            text = value.to_s
            raise ArgumentError, "#{label} #{text.inspect} must match #{pattern.inspect}" unless text.match?(pattern)

            text
          end

          def path_of(path) = matching(path, PATH_PATTERN, "preview container path")

          def port_of(item, name)
            port = Integer(item[:port], exception: false)
            raise ArgumentError, "preview container #{name} needs a port between 1 and 65535" unless port&.between?(1, 65_535)

            port
          end

          def environment_of(environment)
            (environment || {}).to_h { |name, value| [name.to_s, value.to_s] }
          end

          def check!(entries)
            raise ArgumentError, "preview containers must not be empty" if entries.empty?

            %i[name port].each do |field|
              dup = entries.map(&field).tally.find { |_value, count| count > 1 }
              raise ArgumentError, "preview containers repeat the #{field} #{dup.first.inspect}" if dup
            end
            check_roles!(entries)
          end

          def check_roles!(entries)
            raise ArgumentError, "at most one preview container may be the default" if entries.count(&:default) > 1
            raise ArgumentError, "at most one preview container may be the host" if entries.count(&:host) > 1

            bad = entries.flat_map(&:secrets).find { |secret| !secret.match?(ENV_NAME_PATTERN) }
            raise ArgumentError, "preview secret name #{bad.inspect} must be an environment variable name" if bad
          end

          # Skipped when the host is already the default: it gets unmatched traffic anyway.
          def with_signup(entries, signup_path)
            return entries unless signup_path

            entries.map do |entry|
              entry.host && !entry.default ? entry.with(paths: (entry.paths + [signup_path]).uniq) : entry
            end
          end

          def with_default(entries)
            return entries if entries.any?(&:default)

            chosen = entries.find(&:host) || entries.first
            entries.map { |entry| entry.equal?(chosen) ? entry.with(default: true) : entry }
          end
        end
      end
    end
  end
end
