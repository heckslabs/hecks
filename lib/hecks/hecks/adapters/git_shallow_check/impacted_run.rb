# frozen_string_literal: true

require_relative "../git_rehearsal"
require_relative "../bounded_capture"
require_relative "../console_capture"
require_relative "impacted_workers"
require_relative "impacted_batch"

module Hecks
  module Adapters
    class GitShallowCheck
      # Runs the specs a landing's changes touch through the launcher, up to {ImpactedWorkers} at
      # once, inside the world's `spec_bounds` `impacted_seconds`.
      #
      # The files go in batches of {ImpactedBatch::SIZE}: one launcher call, one library boot, for
      # each batch. The budget is read before each batch starts, so it is overrun by at most one
      # batch for each worker. Files that load the whole library run last, so the files a budget
      # leaves unrun are the ones least likely to matter.
      #
      # It reports facts: a red spec raises with its name, and the specs the budget left unrun
      # come back with the seconds spent and the launcher calls made. What an overrun means is the
      # bluebook's: the landing goes on and a finding is filed.
      class ImpactedRun
        # The most spec files one landing maps.
        LIMIT = 200

        # Spec files that load the whole library.
        WHOLE_LIBRARY = /load_hygiene/

        # What ran.
        #
        # @!attribute [r] ran
        #   @return [Array<String>] the spec files that passed
        # @!attribute [r] unrun
        #   @return [Array<String>] the spec files the budget left
        # @!attribute [r] seconds
        #   @return [Integer] whole seconds spent
        # @!attribute [r] calls
        #   @return [Integer] the launcher calls made, each one library boot
        Outcome = Struct.new(:ran, :unrun, :seconds, :calls)

        # @param checkout [String] the branch's worktree
        # @param shell [Shell] runs the launcher
        # @param clock [#call] answers monotonic seconds
        # @param budget [Numeric, nil] seconds allowed; the checkout's world when nil
        # @param workers [#call, nil] given the batch count, answers how many run at once; the
        #   checkout's world held to the load room ({ImpactedWorkers.from_world}) when nil
        def initialize(checkout, shell: Shell.new, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                       budget: nil, workers: nil)
          @checkout = checkout
          @shell = shell
          @budget = budget || BoundedCapture.seconds(checkout, :impacted_seconds)
          @workers = workers || ImpactedWorkers.from_world(checkout)
          @clock = clock
        end

        # @param changed [Array<String>] changed paths relative to the checkout
        # @param base [String] the ref the diff was read against
        # @return [Outcome]
        # @raise [ConsoleCapture::Failure] naming the first spec that is red
        def call(changed, base)
          specs = mapped(changed, base)
          started = @clock.call
          state = { red: nil, lock: Mutex.new, started: started, ran: [], calls: 0 }
          run_all(specs, state)
          raise state[:red] if state[:red]

          Outcome.new(state[:ran], specs - state[:ran], (@clock.call - started).round, state[:calls])
        end

        private

        def run_all(specs, state)
          queue = Queue.new
          specs.each_slice(ImpactedBatch::SIZE) { |batch| queue << batch }
          Array.new(@workers.call(queue.size)) { Thread.new { work(queue, state) } }.each(&:join)
        end

        def work(queue, state)
          pass!(queue.pop(true), state) until state[:red] || @clock.call - state[:started] >= @budget
        rescue ThreadError
          nil
        rescue ConsoleCapture::Failure => e
          state[:lock].synchronize { state[:red] ||= e }
        end

        # Files that load the whole library last, the rest in the order the map gave.
        def mapped(changed, base)
          skips = GitRehearsal::Impacted::Skips.new(@checkout, scratch: -> { false })
          found = GitRehearsal::SpecMap.new(@checkout).map(changed, limit: LIMIT, skip: skips, since: base).specs
          found.partition { |spec| spec.match?(WHOLE_LIBRARY) }.reverse.flatten
        end

        def pass!(batch, state)
          state[:lock].synchronize { state[:calls] += 1 }
          ImpactedBatch.call(@shell, @checkout, batch)
          state[:lock].synchronize { state[:ran].concat(batch) }
        end
      end
    end
  end
end
