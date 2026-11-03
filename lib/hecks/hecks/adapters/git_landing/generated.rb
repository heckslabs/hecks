# frozen_string_literal: true

require_relative "../shell"

module Hecks
  module Adapters
    class GitLanding
      # Refuses a landing whose branch changes a bluebook, hecksagon or generator while the output
      # those produce is stale on that branch. Each projection runs in check mode from the branch's
      # worktree; the first one that would write a different file refuses the landing and names the
      # file and the command that brings it up to date. Nothing is regenerated here: the owner's
      # branch is refused, never rewritten.
      #
      # A branch that changes none of the trigger paths runs no projection.
      class Generated
        # The paths whose change can make generated output stale.
        TRIGGERS = [
          /\.bluebook\z/, /\.hecksagon\z/, %r{\Alib/hecks/tools/}, %r{\Alib/hecks/vocabulary\.rb\z},
          %r{\Alib/hecks/adapters/codebase/}
        ].freeze

        # The first path a projection printed, when it named one.
        STALE_FILE = %r{[\w./-]+\.(?:rs|md|rb|json|toml|yml|yaml)}

        # The glossaries CI compares, by domain folder and bluebook.
        GLOSSARIES = { "examples/pizzas" => "Pizzas", "examples/banking" => "Banking", "qa" => "QualityControl" }.freeze

        # Each projection: its name, the check that only compares, and the command that rewrites.
        PROJECTIONS = [
          ["Rust corpus", %w[regeneration_run.regenerate_corpus! check.value=true --wait],
           "exe/hecks regeneration_run.regenerate_corpus! --confirm --wait"],
          ["language reference", %w[language_run.project_reference! --wait],
           "exe/hecks language_run.project_reference! --confirm --wait"]
        ].freeze

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the worktree the branch is checked out in
        # @param branch [String] the branch being landed
        # @param onto [String] the branch it lands onto
        # @param runner [#call, nil] answers the {Shell::Result} of a command run in a directory
        def initialize(git, checkout, branch:, onto:, runner: nil)
          @git = git
          @checkout = checkout
          @branch = branch
          @onto = onto
          @runner = runner || ->(args, dir) { Shell.new.capture(*args, chdir: dir) }
        end

        # @return [void]
        # @raise [ConsoleCapture::Failure] naming the stale file and the command that rewrites it
        def refuse_stale!
          return unless triggered?

          projections.each { |name, check, fix| refuse_if_stale(name, check, fix) }
        end

        private

        def triggered?
          changed.any? { |path| TRIGGERS.any? { |pattern| path.match?(pattern) } }
        end

        def changed = @git.capture("diff", "--name-only", "#{@onto}...#{@branch}", chdir: @checkout).out.split("\n")

        def projections = corpus_and_reference + glossaries

        def corpus_and_reference
          PROJECTIONS.map { |name, check, fix| [name, ["exe/hecks", *check], fix] }
        end

        def glossaries
          GLOSSARIES.map do |folder, bluebook|
            ["#{bluebook} glossary", glossary_run(folder, bluebook, "check.value=true"),
             glossary_run(folder, bluebook, "--confirm").join(" ")]
          end
        end

        def glossary_run(folder, bluebook, *extra)
          ["exe/hecks", "regeneration_run.project_glossary!", "domain.value=#{folder}",
           "bluebook.value=#{bluebook}", *extra, "--wait"]
        end

        def refuse_if_stale(name, check, fix)
          result = @runner.call(check, @checkout)
          return if result.ok?

          raise ConsoleCapture::Failure, "generated output is stale: #{result.out[STALE_FILE] || name}: run #{fix}"
        end
      end
    end
  end
end
