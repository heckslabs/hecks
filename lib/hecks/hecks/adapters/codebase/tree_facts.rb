# frozen_string_literal: true

require_relative "../git"
require_relative "conformance"

module Hecks
  module Adapters
    module Codebase
      # What a Codebase run's examine reports about the tree it runs in, as raw git facts: whether
      # the tree is a linked worktree and which branch it has checked out. The domain judges from
      # them whose failure it is (a coder's worktree, or main); this module only reads git.
      module TreeFacts
        module_function

        # The facts every Codebase run is examined with, so a failure can be judged and keyed by
        # them: the tree's git facts and `check_name:` the name of what ran, `gate-<stage>`,
        # `conformance-<operation>`, else the operation. Every fact is always answered, since a
        # policy's arguments must stand in the event it reacts to.
        #
        # @param root [String] the tree's root directory
        # @param operation [String] the operation the run names
        # @param stage [String, nil] a gate's stage
        # @return [Hash{Symbol => Hash}] `linked:`, `branch:` and `check_name:`
        def answer(root, operation, stage = nil)
          of(root).merge(check_name: { value: check_name(operation, stage) })
        end

        # @return [String] the name a failure of the operation is filed under
        def check_name(operation, stage)
          return "gate-#{stage}" if operation == "gate"

          Conformance::OPERATIONS.include?(operation) ? "conformance-#{operation}" : operation
        end

        # @param root [String] the tree's root directory
        # @param git [Git] runs git; a new one when nil
        # @return [Hash{Symbol => Hash}] `linked:` whether the git directory is not the common one,
        #   and `branch:` the checked-out branch, `HEAD` when detached; outside git, not linked on
        #   `HEAD`
        def of(root, git: nil)
          git ||= Git.new
          dirs = %w[--git-dir --git-common-dir].map { |flag| said(git, root, "--path-format=absolute", flag) }
          branch = said(git, root, "--abbrev-ref", "HEAD")
          { linked: { value: dirs.none?(&:empty?) && dirs.uniq.size > 1 },
            branch: { value: branch.empty? ? DETACHED : branch } }
        end

        # What git calls a checkout on no branch.
        DETACHED = "HEAD"

        # @return [String] what `git rev-parse` says for the arguments; empty when git fails
        def said(git, root, *)
          result = git.capture("rev-parse", *, chdir: root)
          result.ok? ? result.out.strip : ""
        end
      end
    end
  end
end
