# frozen_string_literal: true

require "json"
require "open3"
require "hecks/vocabulary"
require_relative "../tools"
require_relative "ci_gates"

module Hecks
  module Tools
    # Answers whether a change touches what a gated CI job covers: the decision a `CiGate` row of
    # the Vocabulary chapter names, made by `hecks decide_ci_gate gate=<name>` in the detector job
    # `hecks project_ci_gates` writes into each workflow.
    #
    # The change is read from the run's own event (`GITHUB_EVENT_PATH`) and head (`GITHUB_SHA`),
    # and the answer goes to stdout and, when the runner names one, to `GITHUB_OUTPUT` as
    # `touched=true` or `touched=false`. Every case that cannot confirm a safe diff answers
    # `true`, so a failure here runs the gated job instead of skipping it.
    module CiGateDecision
      NO_COMMIT = "0" * 40

      module_function

      # @param argv [Array<String>] `gate=<name>`, a `CiGate` row's name
      # @param root [String] the checkout whose history is diffed
      # @param env [Hash{String => String}] the runner's environment
      # @return [Integer] 0 once an answer is given
      # @raise [SystemExit] when no row has that name
      def main(argv, root: Tools::ROOT, env: ENV)
        name = argv.filter_map { |arg| arg[/\Agate=(.+)\z/, 1] }.first
        abort "decide_ci_gate: name a gate, gate=<name>" unless name
        gate = CiGates.gates.find { |row| row["name"] == name }
        abort "decide_ci_gate: no CiGate row named #{name}" unless gate

        touched = touched?(gate, root: root, env: env)
        puts "touched=#{touched}"
        File.open(env["GITHUB_OUTPUT"], "a") { |file| file.puts "touched=#{touched}" } if env["GITHUB_OUTPUT"]
        0
      end

      # @param gate [Hash{String => String}] a `CiGate` row
      # @param root [String] the checkout
      # @param env [Hash{String => String}] the runner's environment
      # @return [Boolean] whether the gated job should run
      def touched?(gate, root:, env:)
        changed, reason = change_set(gate, root: root, env: env)
        if reason
          explain(gate, reason)
          return true
        end
        return false if changed.empty?

        matches = changed.map { |path| path.match?(Regexp.new(gate.fetch("pattern"))) }
        gate.fetch("mode") == "touches" ? matches.any? : matches.any?(false)
      end

      # @return [Array(Array<String>, nil), Array(nil, String)] the changed paths, or the reason the
      #   change cannot be confirmed
      def change_set(gate, root:, env:)
        base = base_of(gate, root: root, env: env)
        return [nil, "no usable base to diff against"] if base.nil? || base.empty? || base == NO_COMMIT

        changed = changed_files(base, env.fetch("GITHUB_SHA", "HEAD"), root: root)
        changed.nil? ? [nil, "git diff itself failed"] : [changed, nil]
      end

      # The commit the change is measured against: a pull request's base, or a merge group's
      # merge-base with its target branch, never the group's `base_sha`, which is the previous
      # queue entry and would let an entry queued behind a red one diff as its own files only.
      #
      # @return [String, nil] the commit, or nil when there is none
      def base_of(gate, root:, env:)
        event = event_of(env)
        base = event.dig("pull_request", "base", "sha").to_s
        base = merge_base_of(event, root, env) if env["GITHUB_EVENT_NAME"] == "merge_group"
        base = event["before"].to_s if base.empty? && env["GITHUB_EVENT_NAME"] == "push" && gate["push"] == "before_sha"
        base
      end

      # @return [String] the merge-base of the merge group's target branch and the run's head
      def merge_base_of(event, root, env)
        target = event.dig("merge_group", "base_ref").to_s.delete_prefix("refs/heads/")
        git(root, "merge-base", "origin/#{target}", env.fetch("GITHUB_SHA", "HEAD"))&.strip.to_s
      end

      # @return [Hash] the run's event payload, empty when it cannot be read
      def event_of(env)
        path = env["GITHUB_EVENT_PATH"].to_s
        path.empty? || !File.file?(path) ? {} : JSON.parse(File.read(path))
      rescue JSON::ParserError
        {}
      end

      # @return [Array<String>, nil] the changed paths, or nil when git could not say
      def changed_files(base, head, root:)
        out = git(root, "diff", "--name-only", base, head)
        return nil if out.nil?

        out.lines.map(&:chomp).reject(&:empty?)
      end

      # @return [String, nil] a git command's stdout, or nil when it failed
      def git(root, *)
        out, _err, status = Open3.capture3("git", "-C", root, *)
        status.success? ? out : nil
      end

      # Says why a gate could not be answered; the caller runs the gated job.
      #
      # @return [nil]
      def explain(gate, reason)
        warn "decide_ci_gate: #{reason} (#{gate["label"]}): running the gated job rather than guessing"
      end
    end
  end
end
