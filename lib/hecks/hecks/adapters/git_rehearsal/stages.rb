# frozen_string_literal: true

require_relative "../shell"
require "hecks/vendoring/git_environment"
require "hecks/vocabulary"
require_relative "impacted"
require_relative "coverage"

module Hecks
  module Adapters
    class GitRehearsal
      # The stages a rehearsal runs, run in a copy of the commit. Which ones is data: the
      # `RehearsalScope` row of the scope lists `RehearsalStage` rows of the Vocabulary bluebook
      # (the gate's `quick` stage, the specs the
      # push's changes touch), and this only runs them. Nothing here runs the full spec suite.
      class Stages
        # How one stage ended.
        #
        # @!attribute [r] name
        #   @return [String] the stage
        # @!attribute [r] passed
        #   @return [Boolean] whether it passed
        # @!attribute [r] detail
        #   @return [String] what failed, naming the check and the spec; empty when it passed
        Result = Struct.new(:name, :passed, :detail) do
          # @return [String] the stage, pass or fail, and what failed
          def line = passed ? "#{name}: pass#{detail}" : "#{name}: FAIL #{detail}"
        end

        # The gate script, as the pre-push hook calls it.
        GATE = ["bundle", "exec", "ruby", "-Ilib", "-e", 'require "hecks/tools"; Hecks::Tools.script("gate", ARGV)'].freeze

        # The gate's red verdict line: `[gate quick] red: shape_ledger, rubocop`.
        RED = /^\[gate \S+\] red: ([^;\n]+)/

        # A failing example as rspec prints it in its summary: `rspec ./spec/a_spec.rb:12 # ...`.
        FAILED_SPEC = %r{^rspec (\./\S+)}

        # The variables of the calling process that would point a copy's `bundle exec` at the
        # checkout the rehearsal was asked from.
        BUNDLER = %w[BUNDLE_GEMFILE BUNDLE_BIN_PATH RUBYOPT RUBYLIB].freeze

        # @param directory [String] the copy of the commit the stages run in
        # @param branch [String] the branch pushed; impacted specs compare with `origin/<branch>`
        # @param impacted_limit [Integer, nil] the most impacted spec files to run
        # @param impacted_width [Integer, nil] how many of them run at once
        # @param scope [String] a `RehearsalScope` row: `quick` or `deep`
        def initialize(directory, branch: "main", impacted_limit: nil, impacted_width: nil, scope: "quick")
          @scope = scope
          @directory = directory
          @branch = branch
          @impacted_limit = impacted_limit
          @impacted_width = impacted_width
          @shell = Shell.new
        end

        # @return [Array<Result>] each stage's result, in the order the scope's row lists them,
        #   then what the rehearsal did not cover of CI
        def run = self.class.rows(@scope).map { |row| step(row) } << coverage_result

        # @return [Result] a passing result saying which CI checks the scope ran and which not
        def coverage_result = Result.new("ci coverage", true, Coverage.new(@scope).line)

        # @param scope [String] a scope's name
        # @return [Array<Hash>] the scope's `RehearsalStage` rows, in the order it runs them
        # @raise [KeyError] when no `RehearsalScope` row has that name
        def self.rows(scope)
          stages = Vocabulary.rows("RehearsalStage").to_h { |row| [row["name"], row] }
          scope_row = Vocabulary.rows("RehearsalScope").find { |row| row["name"] == scope }
          raise KeyError, "no rehearsal scope #{scope.inspect}" unless scope_row

          scope_row["stages"].split(",").map { |name| stages.fetch(name) }
        end

        # @return [Array<String>] the names of the rehearsal scopes
        def self.scopes = Vocabulary.rows("RehearsalScope").map { |row| row["name"] }

        private

        def step(row)
          case row["kind"]
          when "gate" then gate(row["argument"])
          else impacted
          end
        end

        def gate(stage)
          result = capture(*GATE, stage, env: { "HECKS_ENVIRONMENT" => "memory" })
          return Result.new(stage, true, "") if result.ok?

          Result.new(stage, false, failure(result, checks: result.out[RED, 1]))
        end

        def failure(result, checks: nil)
          specs = failing_specs(result)
          parts = []
          parts << "failing check: #{checks.strip}" if checks
          parts << "failing spec: #{specs.join(", ")}" unless specs.empty?
          parts << "exit #{result.exit_code}: #{last_line(result)}" if parts.empty?
          parts.join("; ")
        end

        def failing_specs(result) = spec_names(result.out)

        def spec_names(output) = output.scan(FAILED_SPEC).flatten.uniq

        def last_line(result) = printed_lines(result).last.to_s

        def printed_lines(result) = "#{result.out}#{result.err}".lines.map(&:strip).reject(&:empty?)

        def impacted
          runner = ->(directory, *command, env:) { capture(*command, env: env, directory: directory) }
          Impacted.build(@directory, branch: @branch, capture: runner, limit: @impacted_limit, width: @impacted_width).result
        end

        def capture(*command, env:, directory: @directory)
          clean = BUNDLER.to_h { |name| [name, nil] }.merge(Vendoring::GitEnvironment.clean).merge(env)
          @shell.capture(*command, env: clean, chdir: directory)
        end
      end
    end
  end
end
