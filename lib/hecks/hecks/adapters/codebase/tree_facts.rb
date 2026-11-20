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
        # them: the tree's git facts, blank where git says nothing, and `check_name:` the name of
        # what ran, `gate-<stage>`, `conformance-<operation>`, else the operation.
        #
        # @param root [String] the tree's root directory
        # @param operation [String] the operation the run names
        # @param stage [String, nil] a gate's stage
        # @return [Hash{Symbol => Hash}] `linked:`, `branch:` and `check_name:`
        def answer(root, operation, stage = nil)
          { linked: { value: nil }, branch: { value: nil } }
            .merge(of(root))
            .merge(check_name: { value: check_name(operation, stage) })
        end

        # @return [String] the name a failure of the operation is filed under
        def check_name(operation, stage)
          return "gate-#{stage}" if operation == "gate"

          Conformance::OPERATIONS.include?(operation) ? "conformance-#{operation}" : operation
        end

        # @param root [String] the tree's root directory
        # @param git [Git] runs git; a new one when nil
        # @return [Hash{Symbol => Hash}] `linked:` whether the git directory is not the common one,
        #   and `branch:` the checked-out branch, absent on a detached head or outside git
        def of(root, git: nil)
          git ||= Git.new
          dirs = %w[--git-dir --git-common-dir].map { |flag| absolute(git, root, flag) }
          return {} if dirs.any?(&:empty?)

          { linked: { value: dirs.uniq.size > 1 } }.merge(branch(git, root))
        end

        # @return [String] the directory git names for the flag, absolute; empty when git fails
        def absolute(git, root, flag)
          result = git.capture("rev-parse", "--path-format=absolute", flag, chdir: root)
          result.ok? ? result.out.strip : ""
        end

        # @return [Hash{Symbol => Hash}] `branch:` the branch's short name, or nothing when detached
        def branch(git, root)
          result = git.capture("symbolic-ref", "--quiet", "--short", "HEAD", chdir: root)
          name = result.ok? ? result.out.strip : ""
          name.empty? ? {} : { branch: { value: name } }
        end
      end
    end
  end
end
