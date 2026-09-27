module Hecks
  module Projections
    module Deploy
      module Preview
        # The containers one preview task runs, in one normalized shape.
        #
        # A preview task runs the same containers as the stack it previews.
        # This module is the single place that decides which containers those
        # are, so the rest of `Preview` never asks where the list came from.
        #
        # ## One adapter to the shared setting
        #
        # The main Fargate stack is growing a multi-container setting.
        # `shared_setting` is the only method that reads it; every other
        # method here works on the normalized entries described below. When
        # that setting lands with a different shape, translate it inside
        # `shared_setting` and nothing else changes.
        #
        # ## Entry keys
        #
        # Each entry is a Hash with Symbol keys:
        #
        # - `name` (required): lowercase letters, digits and hyphens; also the
        #   container name and the suffix of its ECR repository.
        # - `port` (required): the port the container listens on. Unique
        #   across the task, since all containers share one network namespace.
        # - `health_check_path`: target group health check path, default `"/"`.
        # - `paths`: load balancer path patterns forwarded to this container.
        # - `default`: `true` sends every unmatched request here. When no
        #   entry says so, the `host` entry is the default, else the first.
        # - `host`: `true` marks the Hecks host container. It gets the domain,
        #   session and database environment, and the signup path.
        # - `database`: `true` gives a non-host container the database
        #   environment as well. The host always has it.
        # - `environment`: extra environment, name to value. `{{preview_url}}`
        #   inside a value becomes the preview's public https URL.
        # - `secrets`: environment variable names. Each becomes a per-branch
        #   generated secret whose ARN is that variable's value.
        # - `image`: the local docker image `preview.sh` pushes for this
        #   container, default `"<name>:latest"`.
        module Containers
          # One normalized container of the preview task.
          Entry = Data.define(:name, :port, :health_check_path, :paths, :default, :host, :database,
                              :environment, :secrets, :image) do
            # Answers the CloudFormation logical-id fragment for this container.
            #
            # @return [String] `name` in CamelCase, such as `"MySite"` for `"my-site"`
            def logical = name.split("-").map(&:capitalize).join

            # Answers whether the container is reachable through the load balancer.
            #
            # @return [Boolean] true when it is the default or owns any path
            def routed? = default || !paths.empty?
          end

          NAME_PATTERN = /\A[a-z][a-z0-9-]{0,29}\z/
          PATH_PATTERN = %r{\A/[A-Za-z0-9._~/*?%-]*\z}
          IMAGE_PATTERN = %r{\A[A-Za-z0-9._/:@-]+\z}
          ENV_NAME_PATTERN = /\A[A-Z_][A-Z0-9_]*\z/

          module_function

          # Answers the preview task's containers, normalized and validated.
          #
          # @param preview [Hash{Symbol => Object}] the preview settings; `:containers` wins
          # @param deploy_settings [Hash{Symbol => Object}] the `deployed_to` settings, read
          #   by `shared_setting`
          # @param main [Hash{Symbol => Object}] the main stack's own facts; `:name`, `:port`,
          #   `:image` describe the single container used when neither list is given
          # @param signup_path [String, nil] path forwarded to the host container, or nil
          # @return [Array<Entry>] at least one entry, exactly one of them the default
          # @raise [ArgumentError] if an entry is malformed, a name or port repeats, or two
          #   entries claim to be the default or the host
          def resolve(preview:, deploy_settings:, main:, signup_path: nil)
            raw = preview[:containers] || shared_setting(deploy_settings) || [single(main)]
            entries = Array(raw).map { |item| normalize(item) }
            check!(entries)
            with_default(with_signup(entries, signup_path))
          end

          # Reads the main stack's own container list, when it declares one.
          #
          # This is the one hook to the multi-container setting shared with the
          # main template; it answers entries in the shape documented above.
          #
          # @param deploy_settings [Hash{Symbol => Object}] the `deployed_to` settings
          # @return [Array<Hash>, nil] the list, or nil when the stack runs one container
          def shared_setting(deploy_settings)
            deploy_settings[:containers]
          end

          # Builds the single-container entry a one-container stack previews as.
          #
          # @param main [Hash{Symbol => Object}] the main stack's facts, see `resolve`
          # @return [Hash{Symbol => Object}] the entry, always the host and the default
          def single(main)
            name = main.fetch(:name).to_s.downcase.gsub(/[^a-z0-9]+/, "-").sub(/\A[^a-z]+/, "")[0, 30].sub(/-+\z/, "")
            { name: name, port: main.fetch(:port), host: true, default: true, image: main[:image] }
          end

          # Turns one raw entry into an `Entry`, filling every default.
          #
          # @param item [Hash{Symbol => Object}] the raw entry, string keys accepted
          # @return [Entry] the normalized entry
          # @raise [ArgumentError] if the entry is not a Hash or lacks a valid `name` or `port`
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

          # Answers a value as a String, refusing one that does not match a pattern.
          #
          # @param value [Object] the raw value
          # @param pattern [Regexp] what the string must match
          # @param label [String] what the value is, for the message
          # @return [String] the value as a String
          # @raise [ArgumentError] if the string does not match
          def matching(value, pattern, label)
            text = value.to_s
            raise ArgumentError, "#{label} #{text.inspect} must match #{pattern.inspect}" unless text.match?(pattern)

            text
          end

          # Answers one path pattern, refusing one the template could not quote safely.
          #
          # @param path [Object] the raw path
          # @return [String] the path
          # @raise [ArgumentError] if it does not start with `/` or holds an unexpected character
          def path_of(path) = matching(path, PATH_PATTERN, "preview container path")

          # Reads and range-checks one entry's port.
          #
          # @param item [Hash{Symbol => Object}] the raw entry
          # @param name [String] the entry's name, for the message
          # @return [Integer] the port
          # @raise [ArgumentError] if the port is missing or outside 1..65535
          def port_of(item, name)
            port = Integer(item[:port], exception: false)
            raise ArgumentError, "preview container #{name} needs a port between 1 and 65535" unless port&.between?(1, 65_535)

            port
          end

          # Stringifies an entry's environment, keeping declaration order.
          #
          # @param environment [Hash{Symbol, String => Object}, nil] the raw environment
          # @return [Hash{String => String}] name to value
          def environment_of(environment)
            (environment || {}).to_h { |name, value| [name.to_s, value.to_s] }
          end

          # Refuses a list that cannot be one task.
          #
          # @param entries [Array<Entry>] the normalized entries
          # @return [void]
          # @raise [ArgumentError] on an empty list, a repeated name or port, more than one
          #   default or host, or a secret name that is not an environment variable name
          def check!(entries)
            raise ArgumentError, "preview containers must not be empty" if entries.empty?

            %i[name port].each do |field|
              dup = entries.map(&field).tally.find { |_value, count| count > 1 }
              raise ArgumentError, "preview containers repeat the #{field} #{dup.first.inspect}" if dup
            end
            check_roles!(entries)
          end

          # Refuses a second default or host, and a secret that is not an environment variable name.
          #
          # @param entries [Array<Entry>] the normalized entries
          # @return [void]
          # @raise [ArgumentError] on a second default or host, or a malformed secret name
          def check_roles!(entries)
            raise ArgumentError, "at most one preview container may be the default" if entries.count(&:default) > 1
            raise ArgumentError, "at most one preview container may be the host" if entries.count(&:host) > 1

            bad = entries.flat_map(&:secrets).find { |secret| !secret.match?(ENV_NAME_PATTERN) }
            raise ArgumentError, "preview secret name #{bad.inspect} must be an environment variable name" if bad
          end

          # Adds the signup path to the host container's own paths.
          #
          # @param entries [Array<Entry>] the normalized entries
          # @param signup_path [String, nil] the path, or nil for none
          # @return [Array<Entry>] the entries, the host's paths extended when it needs a rule
          def with_signup(entries, signup_path)
            return entries unless signup_path

            entries.map do |entry|
              entry.host && !entry.default ? entry.with(paths: (entry.paths + [signup_path]).uniq) : entry
            end
          end

          # Marks the default container when no entry does.
          #
          # @param entries [Array<Entry>] the normalized entries
          # @return [Array<Entry>] the entries with exactly one default
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
