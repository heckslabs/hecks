# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "hecks/cache_dir"
require "hecks/rust_build/world_rows"

module Hecks
  module Adapters
    # The machine's one pressure signal as {PressurePosting} last posted it (ADR 0222 law 2,
    # phase 3b): the reader the load guard, the moving cap and the heavy-jobs gate share. The file
    # is the signal; the reader only compares its `posted_at` with its `stale_after`, and answers
    # nothing once it is older (dark), so each reader keeps its own path while the signal is dark.
    module PressureSignal
      # The Tickets world verb whose `drives` switch says whether the readers read the signal.
      VERB = "signalbox_pressure"

      # The band that admits nothing.
      SHORT = "short"

      module_function

      # @param base [#[]] the environment, for `HECKS_CACHE_DIR`
      # @return [String] where the signal is posted
      def path(base = ENV)
        named = base["HECKS_CACHE_DIR"].to_s
        File.join(named.empty? ? Hecks::CacheDir.path("signalbox") : File.join(named, "signalbox"), "pressure.json")
      end

      # @param row [Hash, nil] the Tickets world's `signalbox_pressure` line
      # @return [Boolean] whether the owner turned the readers onto the signal
      def drives?(row) = (row || {}).transform_keys(&:to_sym)[:drives] == true

      # @param path [String] the posted file
      # @param now [Time] the time the signal is read at
      # @return [Hash, nil] `band`, `headroom`, `load`, `cores`, `coders_fit`, `gates_fit`,
      #   `posted_at` and `stale_after`; nil when none was posted, it cannot be read, or it is dark
      def current(path: self.path, now: Time.now)
        signal = JSON.parse(File.read(path), symbolize_names: true)
        signal if now - Time.iso8601(signal[:posted_at].to_s) <= signal[:stale_after].to_i
      rescue SystemCallError, JSON::ParserError, ArgumentError
        nil
      end

      # What a dark signal says of itself, for the board and the status read model. It reads only.
      #
      # @param path [String] the posted file
      # @param now [Time] the time the signal is read at
      # @return [Hash, nil] nil while the signal is current; else `dark:` true, `since:` (when it
      #   went stale, nil when none was posted), `last_post:` (the time it was posted, nil when
      #   never) and `said:`, "signal dark since <t>, last post <t>"
      def dark_report(path: self.path, now: Time.now)
        return if current(path: path, now: now)

        posted = posted_at(path)
        since = posted && (posted + stale_seconds(path))
        { dark: true, since: since&.utc&.iso8601, last_post: posted&.utc&.iso8601, said: dark_said(since, posted) }
      end

      # @param since [Time, nil] when the signal went stale
      # @param posted [Time, nil] when it was last posted
      # @return [String] "signal dark since <t>, last post <t>"
      def dark_said(since, posted)
        "signal dark since #{since ? since.utc.iso8601 : "never posted"}, last post #{posted ? posted.utc.iso8601 : "never"}"
      end

      # @param registry [Runtime::Registry, nil] whose Tickets world carries the switch
      # @param path [String] the posted file
      # @return [Hash, nil] the current signal while the switch is on; nil while it is off or dark
      def standing(registry, path: self.path)
        current(path: path) if drives?(registry&.world("Tickets")&.for_verb(VERB))
      end

      # @param root [String] a hecks checkout whose Tickets world carries the switch
      # @param path [String] the posted file
      # @return [Hash, nil] the current signal while the switch is on; nil while it is off or dark
      def at_root(root, path: self.path)
        current(path: path) if drives?(RustBuild::WorldRows.row(root, VERB))
      end

      # @param path [String] the posted file
      # @return [Time, nil] when the file says it was posted; nil when none can be read
      def posted_at(path)
        Time.iso8601(JSON.parse(File.read(path), symbolize_names: true)[:posted_at].to_s)
      rescue SystemCallError, JSON::ParserError, ArgumentError
        nil
      end

      # @param path [String] the posted file
      # @return [Integer] the seconds the posted file says it stays current
      def stale_seconds(path)
        JSON.parse(File.read(path), symbolize_names: true)[:stale_after].to_i
      rescue SystemCallError, JSON::ParserError
        0
      end

      # @param signal [Hash] a current signal
      # @return [Integer] the coders its headroom fits, none below nought
      def coders(signal) = [signal[:coders_fit].to_i, 0].max

      # @param signal [Hash] a current signal
      # @return [Integer] the gates its headroom fits, none below nought
      def gates(signal) = [signal[:gates_fit].to_i, 0].max

      # @param signal [Hash, nil] a current signal, nil while it does not drive
      # @param cap [Integer] the most heavy-job places the world allows
      # @return [Integer] the gates the signal fits, at least one and at most the cap; the cap
      #   while the signal does not drive
      def places(signal, cap) = signal ? gates(signal).clamp(1, cap) : cap

      # @param signal [Hash] a current signal
      # @return [Boolean] whether it puts the machine in the short band
      def short?(signal) = signal[:band] == SHORT

      # @param signal [Hash] a current signal
      # @return [String] the signal as a reason names it
      def said(signal)
        "pressure #{signal[:band]} (Signalbox): #{coders(signal)} coders fit, #{gates(signal)} gates fit"
      end
    end
  end
end
