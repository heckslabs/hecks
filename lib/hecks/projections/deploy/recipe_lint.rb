# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require_relative "../../cli/project_deploy"

module Hecks
  module Projections
    module Deploy
      # Lints the Makefiles a deploy recipe generates for prod-touching recipes that hide failure.
      # A pattern match over Make and shell text, not a static analyzer: read each message first.
      #
      # The fixtures it lints are rendered in this process by `CLI::ProjectDeploy`; nothing runs
      # `make`, `aws` or `psql`.
      module RecipeLint
        # Commands that touch AWS or a real Postgres; `sam build` stays local, so it is excluded.
        RISKY_REGEX = /\baws\s+(?:cloudformation|ssm|secretsmanager|lambda|ec2)\b|\bpsql\b|DATABASE_URL=|\bsam\s+deploy\b/

        # Deliberately loose: any real statement with "echo" counts; only a missing step matters.
        ECHO_REGEX = /\becho\b/

        # An unconditional `exit 0` statement; `command && exit 0` is one statement, no match.
        BARE_EXIT_ZERO_REGEX = /\Aexit\s+0\s*\z/

        # `exit $?` is only sound right after the command it reports on; an `@echo` resets it.
        DOLLAR_QUESTION_EXIT_REGEX = /\Aexit\s+\$\$?\?\s*\z/

        # Print-only or no-op statements, never the command a nearby `exit $?` reports on.
        BENIGN_REGEX = /\A(?:@)?(?:echo\b|:\s*\z)/

        Violation = Struct.new(:source, :target, :line, :rule, :message, keyword_init: true) do
          # @return [String] the violation as one report line
          def to_s
            "#{source}:#{line}: [#{rule}] target #{target.inspect} — #{message}"
          end
        end

        module_function

        # Maps each target name to its `[line_no, raw_text]` recipe lines, tabs and continuations.
        def parse_targets(text)
          lines = text.lines
          targets = {}
          i = 0
          while i < lines.length
            line = lines[i]
            if line.start_with?("\t", "#") || line.strip.empty? || line.include?(":=") || line.start_with?(".PHONY")
              i += 1
              next
            end

            if (m = line.match(%r{\A([A-Za-z0-9_./$(){}-]+):(?:\s.*)?\z}))
              recipe = []
              j = i + 1
              while j < lines.length && (lines[j] == "\n" || lines[j].start_with?("\t") || lines[j].start_with?("#"))
                recipe << [j, lines[j].chomp]
                j += 1
              end
              targets[m[1]] = recipe
              i = j
            else
              i += 1
            end
          end
          targets
        end

        # Drops comment and blank lines; a comment can quote "sam deploy" or "echo" but never runs.
        def real_statements(recipe_lines)
          recipe_lines.reject { |_, text| text.sub(/\A\t/, "").start_with?("#") || text.strip.empty? }
        end

        # Splits real statements into shell chains; Make runs a backslash-ended run as one shell.
        def shell_chains(recipe_lines)
          chains = []
          current = []
          real_statements(recipe_lines).each do |line_no, text|
            stripped = text.sub(/\A\t/, "")
            continues = stripped.end_with?("\\")
            statement = continues ? stripped.sub(/\\\z/, "").rstrip : stripped
            current << [line_no, statement]
            unless continues
              chains << current
              current = []
            end
          end
          chains << current unless current.empty?
          chains
        end

        # Drops the leading Make `@` and trailing `;` so exit-code checks match the bare statement.
        def normalize_statement(text)
          text.sub(/\A@/, "").strip.sub(/;\s*\z/, "")
        end

        # Flags a chain that runs an AWS/DB command and later hits an unconditional `exit 0`.
        def check_blind_exit_zero(target, chains)
          chains.filter_map do |chain|
            exit_zero = chain.find { |_, stmt| BARE_EXIT_ZERO_REGEX.match?(normalize_statement(stmt)) }
            next unless exit_zero

            risky_before = chain.take_while { |line_no, _| line_no != exit_zero.first }
                                .select { |_, stmt| RISKY_REGEX.match?(stmt) }
            next if risky_before.empty?

            Violation.new(
              target: target, line: exit_zero.first + 1, rule: "UNVERIFIED_EXIT_ZERO",
              message: "unconditional `exit 0` follows an AWS/DB-touching command (line #{risky_before.last.first + 1}: " \
                       "#{risky_before.last.last.strip.inspect}) whose own exit status this chain never checks — a real " \
                       "failure there would still report success."
            )
          end
        end

        # Flags `exit $?` whose preceding statement in the chain is a benign echo/no-op.
        def check_stale_dollar_question(target, chains)
          chains.filter_map do |chain|
            idx = chain.index { |_, stmt| DOLLAR_QUESTION_EXIT_REGEX.match?(normalize_statement(stmt)) }
            next unless idx

            prev = idx.positive? ? chain[idx - 1] : nil
            next unless prev
            next unless BENIGN_REGEX.match?(normalize_statement(prev.last))

            Violation.new(
              target: target, line: chain[idx].first + 1, rule: "STALE_DOLLAR_QUESTION",
              message: "`exit $?` follows a benign statement (line #{prev.first + 1}: #{prev.last.strip.inspect}), " \
                       "not the meaningful command it claims to report on — capture the real command's status into a " \
                       "named variable instead (this codebase's own convention, e.g. `BOOT_STATUS=$$?` ... " \
                       "`exit $$BOOT_STATUS`) and exit that, not a bare $?."
            )
          end
        end

        # Flags a target whose first AWS/DB command has no earlier echo step.
        def check_prod_touch_without_echo(target, recipe_lines)
          ordered = real_statements(recipe_lines)
          first_risky = ordered.find { |_, text| RISKY_REGEX.match?(text) }
          return [] unless first_risky

          seen_echo = ordered.take_while { |line_no, _| line_no != first_risky.first }
                             .any? { |_, text| ECHO_REGEX.match?(text) }
          return [] if seen_echo

          [Violation.new(
            target: target, line: first_risky.first + 1, rule: "PROD_TOUCH_WITHOUT_ECHO",
            message: "touches AWS/DB (#{first_risky.last.strip.inspect}) with no earlier echo/validation step in this " \
                     "recipe naming what it's about to do to a human running it interactively."
          )]
        end

        # Runs all three checks over every target; `source` labels each violation.
        def lint(text, source:)
          targets = parse_targets(text)
          violations = targets.flat_map do |name, recipe_lines|
            chains = shell_chains(recipe_lines)
            check_blind_exit_zero(name, chains) +
              check_stale_dollar_question(name, chains) +
              check_prod_touch_without_echo(name, recipe_lines)
          end
          violations.each { |v| v.source = source }
          violations
        end

        # Writes a minimal bluebook/world pair under `dir` for bin/project_deploy to generate from.
        def write_fixture(dir, basename, world_body, env_local: nil)
          domain_dir = File.join(dir, basename)
          bluebook_dir = File.join(domain_dir, "bluebook")
          FileUtils.mkdir_p(bluebook_dir)
          bluebook_name = basename.split("_").map(&:capitalize).join

          File.write(File.join(bluebook_dir, "#{basename}.bluebook"), <<~BLUEBOOK)
            Hecks.bluebook "#{bluebook_name}" do
              aggregate "Thing" do
                identified_by :name
                attribute :name, ThingName
                value_object "ThingName" do
                  attribute :value, String
                  invariant("named") { !value.to_s.empty? }
                end
                command "Create" do
                  attribute :name, ThingName
                  sets :name
                  emits "ThingCreated"
                end
              end
            end
          BLUEBOOK

          File.write(File.join(bluebook_dir, "#{basename}.world"), <<~WORLD)
            Hecks.world "#{bluebook_name}" do
              deployed_to("AwsLambda") do
                #{world_body}
              end
            end
          WORLD

          File.write(File.join(domain_dir, ".env.local"), env_local) if env_local

          domain_dir
        end

        # Renders one fixture domain's deploy recipe into a scratch directory, in this process.
        #
        # @param dir [String] the scratch directory the fixture and its recipe are written under
        # @param basename [String] the fixture domain's name
        # @param world_body [String] the lines inside `deployed_to("AwsLambda")`
        # @param env_local [String, nil] the fixture's `.env.local`
        # @return [String] the rendered Makefile's path
        # @raise [Hecks::CLI::ProjectDeploy::Refusal] if the recipe cannot be rendered
        def generate!(dir, basename, world_body, env_local: nil)
          domain_dir = write_fixture(dir, basename, world_body, env_local: env_local)
          out = File.join(dir, "deploy", basename)
          CLI::ProjectDeploy.call(domain: domain_dir, out: out)
          File.join(out, "Makefile")
        end

        # Own-RDS, Shared-mode and OAuth domains: together they hit every branch of the builders.
        def fixtures
          {
            "own fixture"    => ["region \"us-east-1\"", nil],
            "shared fixture" => ["region \"us-east-1\"\n    database \"Shared\"\n    owner \"SomeOwner\"", nil],
            "oauth fixture"  => [
              "region \"us-east-1\"\n    web \"Rust\"",
              "GOOGLE_CLIENT_ID=test-client-id.apps.googleusercontent.com\nGOOGLE_CLIENT_SECRET=test-secret\n"
            ]
          }
        end

        # Renders the three representative fixture domains and lints each Makefile.
        #
        # @return [Array<Violation>] every violation found; empty when the recipes are clean
        def lint_fixtures
          Dir.mktmpdir do |dir|
            fixtures.flat_map do |label, (world_body, env_local)|
              basename = "lint_deploy_recipes_fixture_#{label.tr(' ', '_')}"
              path = generate!(dir, basename, world_body, env_local: env_local)
              lint(File.read(path), source: "#{label} (#{path})")
            end
          end
        end

        # Lints Makefiles on disk.
        #
        # @param paths [Array<String>] the Makefiles to lint
        # @return [Array<Violation>] every violation found
        # @raise [ArgumentError] if a path names no file
        def lint_files(paths)
          paths.flat_map do |path|
            raise ArgumentError, "no such file #{path}" unless File.exist?(path)

            lint(File.read(path), source: path)
          end
        end
      end
    end
  end
end
