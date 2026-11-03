# frozen_string_literal: true

require "json"
require_relative "mint_plan/plan"

module Hecks
  module Adapters
    class JournalStore
      module Readings
        # The preflight of a mint, answered from the live store without copying it. It runs
        # every guard the mint runs, each by the function the mint calls, over a connection that
        # refuses writes, and never boots the domain, so it cannot claim an outbox row. The Rust
        # parity pass and the engine run belong to the full rehearsal and are not part of it.
        module MintPlan
          # @param domain [Hash, String] the domain directory
          # @param bluebook [Hash, String, nil] the bluebook of the directory to plan; the first
          #   when absent
          # @param rehearsal_ref [Hash, String, nil] the rehearsal run whose freshness to judge
          # @param rehearsal_watermark [Hash, Integer, nil] the watermark that rehearsal read
          # @param rehearsal_verdict [Hash, String, nil] the verdict that rehearsal gave
          # @return [Hash] `text:` the plan as JSON: per guard `guard`, `status`, `detail`,
          #   `seconds`; the overall `plan`; the `command` to run; the total `seconds`
          # @raise [Runtime::NotFound] if a lower layer refuses outside a guard
          def mint_plan(domain:, bluebook: nil, rehearsal_ref: nil, rehearsal_watermark: nil, rehearsal_verdict: nil)
            answering do
              asked = { bluebook: bluebook, rehearsal_ref: rehearsal_ref, rehearsal_verdict: rehearsal_verdict,
                        rehearsal_watermark: rehearsal_watermark }.transform_values { |value| plain(value) }
              asked[:rehearsal_watermark] &&= asked[:rehearsal_watermark].to_i
              JSON.pretty_generate(Plan.new(plain(domain), **asked).to_h)
            end
          end
        end
      end
    end
  end
end
