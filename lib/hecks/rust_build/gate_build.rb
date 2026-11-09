# frozen_string_literal: true

require "open3"
require_relative "build_lock"
require_relative "build_policy"
require_relative "session_build"

module Hecks
  module RustBuild
    # How a gate check that compiles Rust runs.
    #
    # A check's command is data in the Vocabulary bluebook and CI runs the same text, so it cannot
    # carry the build policy itself. A check such as `rust_clippy` is a shell script that loops
    # `cargo clippy` over the crates, which `BuildLock.compiles?` cannot see in the argument words.
    # Here the script text decides: a check that names `cargo` or `rustc` outside a comment takes
    # the machine-wide build lock for the whole script, runs with the job cap and under `nice`, and
    # builds into the worktree's own slot below the shared root, never the shared directory itself.
    # Cargo keys a path crate by its place in the workspace and judges it fresh by file times, so
    # two worktrees whose sources differ would read each other's results from one directory: a
    # copy with a deliberate compile error and older file times was reported green there. Any
    # other check runs as it did. A stage's own environment is applied last.
    module GateBuild
      # A compiler named as a word in a command or script line.
      COMPILER = /\b(?:cargo|rustc)\b/

      module_function

      # @param run [Array<String>] a check's program and arguments, or `sh -ec` and its script
      # @return [Boolean] whether the check compiles Rust
      def compiles?(run)
        BuildLock.compiles?(run) || run.any? { |word| code_of(word.to_s).match?(COMPILER) }
      end

      # Runs a check, and returns what `Open3.capture2e` does.
      #
      # @param run [Array<String>] the check's program and arguments
      # @param env [Hash{String => String}] the stage's environment, which wins over the policy
      # @param root [String] the checkout the check runs in
      # @param base [#[]] the environment, for the lock's switches and a job cap set by hand
      # @param lock [String] the lock file
      # @return [Array(String, Process::Status)] what the check printed, and its status
      def capture(run, env, root, base: ENV, lock: BuildLock.path)
        return Open3.capture2e(env, *run, chdir: root) unless compiles?(run)

        BuildLock.hold(base: base, file: lock) do |held|
          policy = held.merge(SessionBuild.environment(root: root, base: base, binary: true)).merge(env)
          Open3.capture2e(policy, *SessionBuild.command(run, root: root), chdir: root)
        end
      end

      # @param text [String] a command word or a script
      # @return [String] the text without its comment lines, which may name `cargo` unrun
      def code_of(text) = text.lines.reject { |line| line.lstrip.start_with?("#") }.join
    end
  end
end
