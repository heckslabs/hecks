# frozen_string_literal: true

require "hecks/runtime/adapter_lookup"

module Hecks
  module Adapters
    class GitLanding
      # What may keep a landing off its target: the adapter the project bound to the `Holds` port.
      #
      # Delivery knows no reason to stop a landing of its own; a pipeline that stands above it
      # does (a red main, a boarding in progress), and says so through this port. A hold refuses a
      # landing before it takes its place in the line, a flag refuses one just before it merges
      # onto main, and every landing onto main is recorded with the commit main moved to. A
      # project that binds no adapter has nothing that holds a landing, and records nothing.
      class BoundHolds
        # The port a project binds what holds its landings to.
        PORT = "Holds"

        # @param registry [Runtime::Registry, nil] the booted registry whose adapters are searched
        def initialize(registry)
          @registry = registry
        end

        # @param branch [String] the branch about to land
        # @param onto [String] the branch it lands on
        # @param git_dir [String] the repository's common git directory
        # @return [Hash, nil] what the adapter answered, or nil when the project binds none
        # @raise [ConsoleCapture::Failure] when the landing is held, in the adapter's own words
        def hold(branch, onto, git_dir)
          adapter&.hold(branch: branch, onto: onto, git_dir: git_dir)
        end

        # @param branch [String] the branch about to merge onto main
        # @param git_dir [String] the repository's common git directory
        # @return [Hash, nil] what the adapter answered, or nil when the project binds none
        # @raise [ConsoleCapture::Failure] when main is flagged for the branch, in the adapter's
        #   own words
        def flag(branch, git_dir)
          adapter&.flag(branch: branch, git_dir: git_dir)
        end

        # @param branch [String] the branch that landed on main
        # @param tip [String] main's commit after the landing
        # @param git_dir [String] the repository's common git directory
        # @return [Hash, nil] what the adapter answered, or nil when the project binds none
        def record_landing(branch, tip, git_dir)
          adapter&.record_landing(branch: branch, tip: tip, git_dir: git_dir)
        end

        private

        # A landing made with no booted registry has no project, and so nothing above it.
        def adapter
          return unless @registry.respond_to?(:adapters)
          return unless @registry.adapters.values.any? { |bound| bound.port == PORT }

          @adapter ||= Runtime::AdapterLookup.call(@registry, PORT, asked: "what holds a landing")
        end
      end
    end
  end
end
