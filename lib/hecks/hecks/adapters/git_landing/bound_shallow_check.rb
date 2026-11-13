# frozen_string_literal: true

require "hecks/runtime/adapter_lookup"
require_relative "../git_shallow_check"

module Hecks
  module Adapters
    class GitLanding
      # The shallow check a landing runs after its gate: the adapter the project bound to the
      # `ShallowChecks` port.
      #
      # A shallow check runs the specs of one repository that fail in a depth-1 clone, so what it
      # runs is that repository's own. Hecks binds `GitShallowCheck`, which names its spec files;
      # another project binds its own, or none. Unlike the gate, it is an extra: a project that
      # binds none has no shallow check, and its landing goes on (ADR 0205).
      class BoundShallowCheck
        # The port a project binds its shallow check to.
        PORT = "ShallowChecks"

        # @param registry [Runtime::Registry, nil] the booted registry whose adapters are searched
        def initialize(registry)
          @registry = registry
        end

        # Runs the project's shallow check for a branch, when it has one.
        #
        # @param checkout [String] the branch's worktree
        # @param branch [String] the branch being landed
        # @param onto [String] the branch it lands on
        # @return [Hash, nil] what the adapter answered, or nil when the project binds none
        # @raise [ConsoleCapture::Failure] when the check is red, in the adapter's own words
        def call(checkout, branch, onto)
          adapter&.shallow_check(checkout: checkout, branch: branch, onto: onto)
        end

        private

        # A landing made with no booted registry, as a spec makes one, runs `GitShallowCheck`.
        def adapter
          return GitShallowCheck.new unless @registry.respond_to?(:adapters)
          return unless @registry.adapters.values.any? { |bound| bound.port == PORT }

          Runtime::AdapterLookup.call(@registry, PORT, asked: "a landing's shallow check")
        end
      end
    end
  end
end
