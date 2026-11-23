# frozen_string_literal: true

require "time"
require "digest"
require "json"

module Hecks
  module Adapters
    module PipelineBoard
      # What is pushed to one reader, when the journal says something happened and not before: each
      # event of the state's `events` section once, oldest first, and again when the reactions to it
      # change; the board's state and the wiring's digest when they change; and the HTML of each
      # tile the journal line changed. The state is read once for each wake and the events are
      # taken from it, so a reader costs the journal no read of its own. A reader that joins is
      # sent every tile as it stands. It waits on the hub, so an idle board does nothing; the hub's
      # safety net wakes it, and then it sends a heartbeat. It ends when the reader goes away,
      # because the write the caller does for each event then raises.
      class Stream
        # Seconds an idle stream waits for a wake before it asks whether its reader has gone.
        PROBE_SECONDS = 2

        # @param hub [#join, #leave, #current] the journal's wakes (see {Hub})
        # @param state [#call, nil] answers the board's state hash (see {Snapshot#latest}), whose
        #   `events` are the newest events, newest first, or `{unknown: reason}`
        # @param wiring [#call, nil] answers the wiring with its `digest`, or `{unknown: reason}`
        # @param gone [#call, nil] answers whether the reader has hung up; asked while idle, so a
        #   reader that left ends the stream without waiting for a write to fail
        def initialize(hub:, state: nil, wiring: nil, gone: nil)
          @hub = hub
          @gone = gone
          @state = state
          @wiring = wiring
          @seen = {}
          @state_digest = nil
          @wiring_digest = nil
        end

        # @yieldparam event [Hash] an event row, an `unknown` note, a `state` hash, a `wiring`
        #   digest, a `tile` fragment or a heartbeat
        def each(&emit)
          wakes = @hub.join
          @hub.current.each { |fragment| yield({ tile: fragment.to_h }) }
          catch(:gone) { follow(wakes, &emit) }
        ensure
          @hub.leave(wakes) if wakes
        end

        private

        def follow(wakes, &)
          loop do
            look_board(&)
            look_wiring(&)
            wait(wakes, &)
          end
        end

        # Waits for the next wake, takes the ones that came with it, and pushes their fragments.
        def wait(wakes, &)
          pending = [next_wake(wakes)]
          pending << wakes.pop until wakes.empty?
          pending.flat_map(&:fragments).each { |fragment| yield({ tile: fragment.to_h }) }
          yield({ heartbeat: Time.now.utc.iso8601 }) if pending.any?(&:net)
        end

        # The next wake. While none comes the reader is asked every `PROBE_SECONDS` whether it is
        # still there, which reads nothing and draws nothing, and the stream ends if it is not.
        def next_wake(wakes)
          loop do
            wake = wakes.pop(timeout: PROBE_SECONDS)
            return wake if wake

            throw :gone if @gone&.call
          end
        end

        # Says the wiring is drawn differently: once on first look, then whenever its digest moves.
        # The page that is told fetches `/api/wiring` again.
        def look_wiring
          digest = @wiring&.call&.dig(:digest)
          return if digest.nil? || digest == @wiring_digest

          @wiring_digest = digest
          yield({ wiring: { digest: digest, at: Time.now.utc.iso8601 } })
        end

        # Reads the state once and pushes what moved in it: its events, then the state itself.
        def look_board(&)
          return unless @state

          current = @state.call
          look(current[:events], &)
          look_state(current, &)
        end

        # The events section: rows, an `unknown` note (the first read is one), or none in the state.
        def look(rows, &emit)
          return note(rows[:unknown], &emit) if rows.is_a?(Hash)

          Array(rows).reverse_each { |row| once(row, &emit) }
          forget(Array(rows))
        end

        # Forgets the events that have left the feed, so what a stream remembers stays the size of
        # the feed however long it is open.
        def forget(rows)
          shown = rows.to_h { |row| [row[:key], true] }
          @seen.select! { |key, _| key == :unknown || shown[key] }
        end

        def look_state(current)
          mark = mark_of(current)
          return if mark == @state_digest

          @state_digest = mark
          yield({ state: current })
        end

        # What tells one state from the next: the `version` a held state carries, with whether it
        # is stale and its last error, so a wake compares three values. A state with no version
        # is digested whole.
        def mark_of(current)
          return current.values_at(:version, :stale, :refresh_error) if current.key?(:version)

          Digest::SHA1.hexdigest(JSON.generate(current.except(:generated_at, :stale_seconds)))
        end

        def once(row)
          digest = row.hash
          yield row unless @seen[row[:key]] == digest
          @seen[row[:key]] = digest
        end

        def note(reason)
          yield({ unknown: reason }) unless @seen[:unknown] == reason
          @seen[:unknown] = reason
        end
      end
    end
  end
end
