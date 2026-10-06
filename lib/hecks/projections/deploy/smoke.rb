module Hecks
  module Projections
    module Deploy
      # The smoke-test files a deployed stack can opt in to: a client-independent harness
      # plus a scheduled GitHub Actions workflow, merged into whatever the deploy target made.
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

        def resolve(deploy_settings)
          missing = REQUIRED.reject { |name| deploy_settings[setting_key(name)] }
          unless missing.empty?
            raise ArgumentError, "smoke true needs #{missing.map { |name| setting_key(name) }.join(", ")} " \
                                 "in the deployed_to block; the workflow cannot be rendered without them"
          end

          picked = PATTERNS.keys.to_h { |name| [name, deploy_settings.fetch(setting_key(name), DEFAULTS[name])] }
          PATTERNS.each do |name, pattern|
            next if picked[name].nil? || picked[name].to_s.match?(pattern)

            raise ArgumentError, "#{setting_key(name)} #{picked[name].inspect} is not a value the smoke workflow can carry"
          end
          picked
        end

        # The region has no `smoke_` prefix; every other setting does.
        def setting_key(name)
          name == :region ? :region : :"smoke_#{name}"
        end

        # A placeholder line that resolves to nothing disappears whole, not as a blank line.
        def render(template, values)
          filled = template.gsub(/^@@setup@@\n/) { setup_step(values[:setup]) }
          filled = filled.gsub("@@secret_field_pipe@@") { secret_field_pipe(values[:secret_field]) }
          values.except(:setup, :secret_field).each { |key, value| filled = filled.gsub("@@#{key}@@") { value.to_s } }
          raise ArgumentError, "unfilled placeholder in the smoke workflow" if filled.include?("@@")

          filled
        end

        def setup_step(command)
          return "" if command.nil?

          "      - name: Set up the smoke run\n        run: '#{command.gsub("'", "''")}'\n\n"
        end

        def secret_field_pipe(field)
          return "" if field.nil?

          " | node -e 'process.stdout.write(JSON.parse(require(\"fs\").readFileSync(0)).#{field})'"
        end
      end
    end
  end
end
