# frozen_string_literal: true

require_relative "shell"
require_relative "main_spec_run"

module Hecks
  module Adapters
    # What is true of the first commit a branch holds since `main`: the files it changes and what
    # the spec files it adds do against `main`'s tree. It reports facts and judges none of them;
    # whether the branch started test-first is the Coder bluebook's.
    class FirstCommitFacts
      # A spec file, and a behaviors file.
      SPEC = %r{\Aspec/.+_spec\.rb\z}
      BEHAVIORS = /\.behaviors\z/

      # @param shell [Shell] runs git
      # @param main_run [#call] answers how the given spec files fare on main, as {MainSpecRun#call}
      def initialize(shell: Shell.new, main_run: MainSpecRun.new)
        @shell = shell
        @main_run = main_run
      end

      # @param checkout [String] the directory the branch is checked out in
      # @return [Hash{Symbol => String}] `first_paths:` the first commit's files joined by `|`,
      #   `first_spec:` none, unchecked, passed, failed or errored, and `first_example:` the first
      #   example that failed on main, empty when none did
      # @raise [ConsoleCapture::Failure] when git cannot read the branch
      def of(checkout)
        first = first_commit(checkout)
        paths = first ? changed(checkout, first) : []
        { first_paths: paths.join("|"), first_example: "" }.merge(spec_facts(checkout, first, paths))
      end

      private

      def spec_facts(checkout, first, paths)
        specs = paths.grep(SPEC)
        return { first_spec: "none" } if specs.empty? && paths.grep(BEHAVIORS).empty?
        return { first_spec: "unchecked" } if specs.empty?

        @main_run.call(checkout, first, specs)
      end

      def first_commit(checkout)
        sha = oldest_since_main(checkout)
        sha.empty? ? nil : sha
      end

      def oldest_since_main(checkout)
        git(checkout, "rev-list", "--reverse", "main..HEAD").lines.first.to_s.strip
      end

      def changed(checkout, sha)
        git(checkout, "diff-tree", "--no-commit-id", "--name-only", "-r", "--root", sha).lines.map(&:strip)
      end

      def git(checkout, *args)
        answer = @shell.capture("git", *args, chdir: checkout)
        raise ConsoleCapture::Failure, "git #{args.first} failed: #{answer.err.strip}" unless answer.ok?

        answer.out
      end
    end
  end
end
