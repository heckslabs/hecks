module Hecks
  module Projections
    module Deploy
      # The smoke-test files a deployed stack can opt in to: a client-independent
      # JavaScript harness and a GitHub Actions workflow that runs it on a schedule.
      #
      # Not a registered `Projector::Target` of its own. It adds files to whatever a
      # deploy target already produced, so `bin/project_deploy` merges what `files`
      # returns into the artifact, and a stack that has not opted in gets nothing.
      #
      # ## Opting in
      #
      # In the domain's `.world`, inside its `deployed_to` block:
      #
      #     deployed_to("AwsFargate") do
      #       smoke true
      #       smoke_role_arn "arn:aws:iam::123456789012:role/example-smoke"
      #       smoke_secret_id "example-stack/session-secret"
      #       smoke_site_url "https://example.org"
      #     end
      #
      # `smoke_secret_field` names a JSON field when the secret is a JSON document,
      # `smoke_secret_env` names the variable the harness reads it from (default
      # `SESSION_SECRET`), `smoke_schedule` is a cron expression (default every 15
      # minutes), `smoke_harness` and `smoke_config` are the repository-relative paths
      # the workflow runs (defaults `smoke/harness.js` and `smoke/config.js`), and
      # `smoke_setup` is one shell command run before the AWS steps, such as an
      # install step the client's checks need.
      #
      # ## What stays with the client
      #
      # The harness knows nothing about any site. The pages and flows to assert, the
      # cookie name, and the expected-era file are the client's own `config.js`, which
      # this never writes.
      module Smoke
        TEMPLATES = File.expand_path("smoke", __dir__).freeze
        DEFAULTS = {
          secret_env: "SESSION_SECRET",
          schedule:   "*/15 * * * *",
          harness:    "smoke/harness.js",
          config:     "smoke/config.js"
        }.freeze

        # Each value is checked against the shape it is spliced into, so a setting
        # can never break out of the YAML or shell line it lands on.
        PATTERNS = {
          role_arn:     %r{\Aarn:aws:iam::\d{12}:role/[\w+=,.@/-]+\z},
          secret_id:    %r{\A[\w/+=.@-]+\z},
          secret_field: /\A\w+\z/,
          secret_env:   /\A[A-Z_][A-Z0-9_]*\z/,
          site_url:     %r{\Ahttps?://[\w.-]+(:\d+)?(/[\w./-]*)?\z},
          schedule:     /\A(\S+ ){4}\S+\z/,
          harness:      %r{\A[\w./-]+\z},
          config:       %r{\A[\w./-]+\z},
          region:       /\A[a-z]{2}(-[a-z]+)+-\d\z/,
          setup:        /\A[^\r\n]+\z/
        }.freeze
        REQUIRED = %i[role_arn secret_id site_url region].freeze

        module_function

        # Whether the domain's `deployed_to` settings ask for the smoke files.
        #
        # @param deploy_settings [Hash{Symbol => Object}] the `deployed_to` block's settings
        # @return [Boolean] true only when `smoke true` was declared
        def enabled?(deploy_settings)
          deploy_settings[:smoke] == true
        end

        # The files to add to a deploy artifact: the harness, and the workflow rendered
        # from the domain's settings. Empty unless the domain opted in.
        #
        # @param deploy_settings [Hash{Symbol => Object}] the `deployed_to` block's settings;
        #   `:region` and the `smoke_*` settings are read
        # @param stack_name [String] names the workflow
        # @return [Hash{String => String}] `"smoke/harness.js"` and `"smoke/workflow.yml"`,
        #   or `{}` when the domain did not opt in
        # @raise [ArgumentError] if a required setting is missing or a value is not in the
        #   shape its place in the workflow allows
        def files(deploy_settings, stack_name:)
          return {} unless enabled?(deploy_settings)

          values = resolve(deploy_settings).merge(name: "#{stack_name} smoke test")
          {
            "smoke/harness.js"   => File.read(File.join(TEMPLATES, "harness.js")),
            "smoke/workflow.yml" => render(File.read(File.join(TEMPLATES, "workflow.yml.tmpl")), values)
          }
        end

        # Applies the defaults and validates every value.
        #
        # @param deploy_settings [Hash{Symbol => Object}] the `deployed_to` block's settings
        # @return [Hash{Symbol => String, nil}] the template values, keyed by placeholder name
        # @raise [ArgumentError] if a required setting is missing or a value does not match its
        #   pattern
        def resolve(deploy_settings)
          missing = REQUIRED.reject { |name| deploy_settings[setting_key(name)] }
          unless missing.empty?
            raise ArgumentError, "smoke true needs #{missing.map { |name| setting_key(name) }.join(', ')} " \
                                 "in the deployed_to block; the workflow cannot be rendered without them"
          end

          picked = PATTERNS.keys.to_h { |name| [name, deploy_settings.fetch(setting_key(name), DEFAULTS[name])] }
          PATTERNS.each do |name, pattern|
            next if picked[name].nil? || picked[name].to_s.match?(pattern)

            raise ArgumentError, "#{setting_key(name)} #{picked[name].inspect} is not a value the smoke workflow can carry"
          end
          picked
        end

        # The `deployed_to` setting that supplies a template value. The region is the
        # deploy target's own; every other value has a `smoke_` prefix.
        #
        # @param name [Symbol] a template value name, such as `:role_arn`
        # @return [Symbol] the setting key, such as `:smoke_role_arn`
        def setting_key(name)
          name == :region ? :region : :"smoke_#{name}"
        end

        # Fills the workflow template. A placeholder line that resolves to nothing
        # disappears whole rather than leaving a blank.
        #
        # @param template [String] the workflow template text
        # @param values [Hash{Symbol => String, nil}] placeholder values, plus `:name`
        # @return [String] the rendered workflow
        # @raise [ArgumentError] if a placeholder is left unfilled
        def render(template, values)
          filled = template.gsub(/^@@setup@@\n/) { setup_step(values[:setup]) }
          filled = filled.gsub("@@secret_field_pipe@@") { secret_field_pipe(values[:secret_field]) }
          values.except(:setup, :secret_field).each { |key, value| filled = filled.gsub("@@#{key}@@") { value.to_s } }
          raise ArgumentError, "unfilled placeholder in the smoke workflow" if filled.include?("@@")

          filled
        end

        # Renders the optional setup step, quoting the command for YAML.
        #
        # @param command [String, nil] the shell command from `smoke_setup`
        # @return [String] a workflow step running it, or nothing
        def setup_step(command)
          return "" if command.nil?

          "      - name: Set up the smoke run\n        run: '#{command.gsub("'", "''")}'\n\n"
        end

        # Builds the pipe that pulls one field out of a JSON secret document.
        #
        # @param field [String, nil] the JSON field of the secret document
        # @return [String] the pipe that extracts it, or nothing when the secret is plain text
        def secret_field_pipe(field)
          return "" if field.nil?

          " | node -e 'process.stdout.write(JSON.parse(require(\"fs\").readFileSync(0)).#{field})'"
        end
      end
    end
  end
end
