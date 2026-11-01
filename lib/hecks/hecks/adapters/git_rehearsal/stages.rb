# frozen_string_literal: true

require_relative "../shell"
require "hecks/vendoring/git_environment"

module Hecks
  module Adapters
    class GitRehearsal
      # The stages a real push runs, run in a copy of the commit: the `quick` stage, the
      # `unguarded_push` stage of the Vocabulary gate rows, and the end-to-end push specs.
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

        # The names of the end-to-end push specs.
        PUSH_SPECS = "spec/**/*{push_chain,push_train}*_spec.rb"

        # The variables of the calling process that would point a copy's `bundle exec` at the
        # checkout the rehearsal was asked from.
        BUNDLER = %w[BUNDLE_GEMFILE BUNDLE_BIN_PATH RUBYOPT RUBYLIB].freeze

        # @param directory [String] the copy of the commit the stages run in
        def initialize(directory)
          @directory = directory
          @shell = Shell.new
        end

        # @return [Array<Result>] each stage's result, in the order a push runs them
        def run
          [gate("quick"), gate("unguarded_push"), push_specs]
        end

        private

        def gate(stage)
          result = capture(*GATE, stage, env: { "HECKS_ENVIRONMENT" => "memory" })
          return Result.new(stage, true, "") if result.ok?

          Result.new(stage, false, failure(result, checks: result.out[RED, 1]))
        end

        def push_specs
          files = Dir.glob(File.join(@directory, PUSH_SPECS)).map { |path| path.delete_prefix("#{@directory}/") }.sort
          return Result.new("push specs", true, " (none exist yet)") if files.empty?

          result = capture("bundle", "exec", "rspec", *files, env: { "CI" => "true", "HECKS_ENVIRONMENT" => "memory" })
          return Result.new("push specs", true, " (#{files.join(", ")})") if result.ok?

          Result.new("push specs", false, failure(result))
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

        def capture(*command, env:)
          clean = BUNDLER.to_h { |name| [name, nil] }.merge(Vendoring::GitEnvironment.clean).merge(env)
          @shell.capture(*command, env: clean, chdir: @directory)
        end
      end
    end
  end
end
