# frozen_string_literal: true

require_relative "probe"

module Hecks
  module Adapters
    module PipelineBoard
      # Lets one reader thread at a time into each ledger the board reads in this process. The
      # sections of one reader are asked side by side, and a ledger that is locked or being
      # compacted made every one of them sleep in the database's busy handler at once, each
      # waiting for the interpreter lock to wake. Through the gate the first asks and the rest
      # answer unknown after {WAIT_SECONDS}, so their sections show the last answer as stale; a
      # holder stuck in the ledger keeps the gate, and its sections stay stale until it returns.
      module LedgerGate
        # The readers whose answers come from a database file the board shares with the launcher.
        LEDGERS = %i[tickets jobs integration].freeze
        # Seconds a reader waits its turn; well under the seconds a reader has to answer.
        WAIT_SECONDS = 5
        # Seconds between looks at the gate.
        LOOK_SECONDS = 0.05

        GATES = LEDGERS.to_h { |name| [name, Mutex.new] }.freeze

        # @param reader [Symbol] the reader asked: a shared ledger's, or another (which passes)
        # @param wait [Numeric] seconds to wait for the turn
        # @yield the read
        # @return [Object] what the read answers
        # @raise [PipelineBoard::Unavailable] when the turn did not come within `wait`
        def self.through(reader, wait: WAIT_SECONDS, &)
          gate = GATES[reader]
          return yield unless gate
          raise Unavailable, "the #{reader} ledger is busy: another read holds it" unless taken?(gate, wait)

          begin
            yield
          ensure
            gate.unlock
          end
        end

        # @return [Boolean] whether the gate was taken within `wait` seconds
        def self.taken?(gate, wait)
          limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
          until gate.try_lock
            return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= limit

            sleep(LOOK_SECONDS)
          end
          true
        end
      end
    end
  end
end
