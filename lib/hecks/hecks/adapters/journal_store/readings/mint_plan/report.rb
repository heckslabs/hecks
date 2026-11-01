# frozen_string_literal: true

module Hecks
  module Adapters
    class JournalStore
      module Readings
        module MintPlan
          # The guards a plan has run, in order, each with its status, its words and the seconds it
          # took, and the plan they add up to.
          class Report
            STATUSES = %w[pass refuse skipped info].freeze

            attr_reader :guards

            def initialize
              @guards = []
              @started = now
              @settled = nil
            end

            # Runs a guard's check, which answers `[status, detail]`, and records it with its
            # time. A refusal the mint raises as a `WiringError` is the guard's refusal.
            #
            # @param name [String] the guard
            # @yieldreturn [Array(Symbol, String)] the status and the detail
            # @return [String] the status recorded
            def check(name)
              began = now
              status, detail = yield
              record(name, status, detail, began)
            rescue Runtime::WiringError, Runtime::NotFound => e
              record(name, :refuse, e.message.strip, began)
            end

            # @return [String] the status recorded
            def add(name, status, detail) = record(name, status, detail, now)

            # @param names [Array<String>] guards that did not run
            # @param why [String] the reason, which is the guard that stopped the plan
            # @return [void]
            def skip(names, why) = names.each { |name| add(name, :skipped, why) }

            # Fixes the plan whatever the guards say: a shape that did not move, a disposable
            # ledger.
            #
            # @param plan [String] `no_change` or `disposable`
            # @return [void]
            def settle(plan) = @settled = plan

            # @return [Boolean] whether a guard refused
            def refused? = guards.any? { |guard| guard[:status] == "refuse" }

            # @return [String] `would_mint`, `would_refuse`, `no_change` or `disposable`
            def plan = @settled || (refused? ? "would_refuse" : "would_mint")

            # @return [Float] the seconds since the plan began
            def seconds = (now - @started).round(3)

            private

            def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

            def record(name, status, detail, began)
              guards << { guard: name, status: status.to_s, detail: detail, seconds: (now - began).round(3) }
              status.to_s
            end
          end
        end
      end
    end
  end
end
