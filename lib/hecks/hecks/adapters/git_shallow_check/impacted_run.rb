# frozen_string_literal: true

require_relative "../git_rehearsal"
require_relative "../bounded_capture"
require_relative "../console_capture"

module Hecks
  module Adapters
    class GitShallowCheck
      # Runs the specs a landing's changes touch, one at a time through the launcher, inside the
      # world's `spec_bounds` `impacted_seconds`.
      #
      # It reports facts: a red spec raises with its name, and the specs the budget left unrun
      # come back with the seconds spent. What an overrun means is the bluebook's: the landing
      # goes on and a finding is filed.
      class ImpactedRun
        # The most spec files one landing maps.
        LIMIT = 200

        # What ran.
        #
        # @!attribute [r] ran
        #   @return [Array<String>] the spec files that passed
        # @!attribute [r] unrun
        #   @return [Array<String>] the spec files the budget left
        # @!attribute [r] seconds
        #   @return [Integer] whole seconds spent
        Outcome = Struct.new(:ran, :unrun, :seconds)

        # @param checkout [String] the branch's worktree
        # @param shell [Shell] runs the launcher
        # @param clock [#call] answers monotonic seconds
        # @param budget [Numeric, nil] seconds allowed; the checkout's world when nil
        def initialize(checkout, shell: Shell.new, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                       budget: nil)
          @checkout = checkout
          @budget = budget || BoundedCapture.seconds(checkout, :impacted_seconds)
          @clock = clock
          @run = GitRehearsal::Impacted::SpecRun.new(->(dir, *argv, env: {}) { shell.capture(*argv, env: env, chdir: dir) })
        end

        # @param changed [Array<String>] changed paths relative to the checkout
        # @param base [String] the ref the diff was read against
        # @return [Outcome]
        # @raise [ConsoleCapture::Failure] naming the first spec that is red
        def call(changed, base)
          specs = mapped(changed, base)
          started = @clock.call
          ran = []
          specs.each do |spec|
            break if @clock.call - started >= @budget

            pass!(spec, ran)
          end
          Outcome.new(ran, specs - ran, (@clock.call - started).round)
        end

        private

        def mapped(changed, base)
          skips = GitRehearsal::Impacted::Skips.new(@checkout, scratch: -> { false })
          GitRehearsal::SpecMap.new(@checkout).map(changed, limit: LIMIT, skip: skips, since: base).specs
        end

        def pass!(spec, ran)
          outcome = @run.call(@checkout, spec)
          raise ConsoleCapture::Failure, "impacted specs red: #{outcome.line}" unless outcome.passed

          ran << spec
        end
      end
    end
  end
end
