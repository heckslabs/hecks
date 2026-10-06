# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "hecks"
require_relative "../tools"
require_relative "deploy_recipe"
require_relative "../hecks/adapters/console_capture"
require_relative "deploy_recipe_lint/makefile"
require_relative "deploy_recipe_lint/checks"
require_relative "deploy_recipe_lint/fixtures"

module Hecks
  module Tools
    # Lints generated deploy Makefiles for prod-touching recipes that hide failure.
    module DeployRecipeLint
      # Commands that touch AWS or a real Postgres; `sam build` is excluded because it stays local.
      RISKY_REGEX = /\baws\s+(?:cloudformation|ssm|secretsmanager|lambda|ec2)\b|\bpsql\b|DATABASE_URL=|\bsam\s+deploy\b/

      # Deliberately loose: any real statement with "echo" counts, since only a missing step
      # matters.
      ECHO_REGEX = /\becho\b/

      # An unconditional `exit 0` statement; `command && exit 0` is one statement and never matches.
      BARE_EXIT_ZERO_REGEX = /\Aexit\s+0\s*\z/

      # `exit $?` is only sound right after the command it reports on; an `@echo` in between
      # resets it.
      DOLLAR_QUESTION_EXIT_REGEX = /\Aexit\s+\$\$?\?\s*\z/

      # Print-only or no-op statements, never the command a nearby `exit $?` reports on.
      BENIGN_REGEX = /\A(?:@)?(?:echo\b|:\s*\z)/

      Violation = Struct.new(:source, :target, :line, :rule, :message, keyword_init: true) do
        def to_s
          "#{source}:#{line}: [#{rule}] target #{target.inspect} — #{message}"
        end
      end

      extend Makefile
      extend Checks
      extend Fixtures

      module_function

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

      # Lints the Makefiles named in `argv`, or three generated fixture domains when there are none.
      #
      # @param argv [Array<String>] Makefile paths, or `-h`/`--help`
      # @param root [String] the checkout the fixtures are generated into
      # @return [Integer] 0 when clean, 1 when a violation was found
      def main(argv, root: Tools::ROOT)
        return usage if %w[-h --help].include?(argv.first)

        generated_dirs = []
        begin
          report(argv.empty? ? lint_fixtures(root, generated_dirs) : lint_files(argv))
        ensure
          generated_dirs.each { |dir| FileUtils.rm_rf(dir) }
        end
      end

      # Generates each fixture domain's recipes, noting their directories in `generated_dirs`.
      #
      # @return [Array<Violation>] what the lint found in their Makefiles
      def lint_fixtures(root, generated_dirs)
        fixtures.flat_map do |label, (world_body, env_local)|
          basename = "lint_deploy_recipes_fixture_#{label.tr(" ", "_")}"
          dir = generate!(root, basename, world_body, env_local: env_local)
          generated_dirs << dir
          makefile_path = File.join(dir, "Makefile")
          lint(File.read(makefile_path), source: "#{label} (#{makefile_path})")
        end
      end

      # @return [Array<Violation>] what the lint found in the named Makefiles
      def lint_files(paths)
        paths.flat_map do |path|
          File.exist?(path) or abort "hecks deploy lint: no such file #{path}"
          lint(File.read(path), source: path)
        end
      end

      # @return [Integer] 0, after printing the usage
      def usage
        puts "usage: hecks deploy lint [Makefile ...]"
        puts "  no args: generates 3 representative fixture domains (own/shared/oauth)"
        puts "           via the real deploy generator, lints each one's Makefile"
        puts "  with args: lints the given Makefile(s) directly (e.g. deploy/<domain>/Makefile)"
        0
      end

      # @param violations [Array<Violation>] what the lint found
      # @return [Integer] 0 when there are none, 1 after printing them to stderr
      def report(violations)
        if violations.empty?
          puts "hecks deploy lint: no violations found."
          return 0
        end

        warn "hecks deploy lint: #{violations.size} violation(s) found:\n\n"
        violations.each { |v| warn "  #{v}\n" }
        1
      end
    end
  end
end
