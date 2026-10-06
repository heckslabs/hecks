# frozen_string_literal: true

require "tempfile"
require_relative "../../tools"

module Hecks
  module Tools
    module FuzzSweep
      # Runs one forked child per domain and prints their output in domain order.
      module Pool
        # Forks one child per domain, up to `workers`, printing each child's output whole in domain
        # order. A child that crashes exits non-zero and counts as a finding.
        #
        # @param domains [Array<String>] the domain directories
        # @param workers [Integer] how many children may run at once
        # @yieldparam domain [String] a domain directory
        # @yieldreturn [Boolean] whether it was clean
        # @return [Boolean] true if every domain's child exited 0, false if any exited non-zero
        def fuzz_in_pool(domains, workers, &) # rubocop:disable Naming/PredicateMethod -- the sweep's verdict
          results = run_children(domains, workers, &)
          slowest = results.max_by(5) { |_, (_, _, seconds)| seconds }
                           .map { |index, (_, _, seconds)| "#{File.basename(domains[index])} #{seconds.round}s" }
          warn "slowest domains: #{slowest.join(", ")}"
          replay_outputs(results).all?
        end

        private

        # @return [Hash{Integer => Array}] by domain index: whether the child succeeded, its output
        #   file, and its seconds
        def run_children(domains, workers, &)
          pending = domains.each_with_index.to_a
          running = {}
          results = {}
          until pending.empty? && running.empty?
            start_children(pending, running, workers, &)
            pid, status = Process.wait2
            index, out, started = running.delete(pid)
            results[index] = [status.success?, out, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
          end
          results
        end

        def start_children(pending, running, workers, &)
          while running.size < workers && (domain, index = pending.shift)
            out = Tempfile.new("fuzz")
            pid = fork_child(out, domain, &)
            running[pid] = [index, out, Process.clock_gettime(Process::CLOCK_MONOTONIC)]
          end
        end

        def fork_child(out, domain)
          fork do
            $stdout.reopen(out)
            $stderr.reopen(out)
            exit(yield(domain) ? 0 : 1)
          end
        end

        # Prints each child's output in domain order.
        #
        # @return [Array<Boolean>] whether each child was clean
        def replay_outputs(results)
          results.sort.map do |_, (clean, out, _)|
            out.rewind
            print out.read
            out.close!
            clean
          end
        end
      end
    end
  end
end
