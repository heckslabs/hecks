# frozen_string_literal: true

require "json"
require "time"
require "fileutils"

module Hecks
  module Adapters
    # The marker file that quiets QA for a mint window. While a fresh marker exists, `hecks
    # quality_control sweep.tick` refuses to start any step (it prints `quiesced: skipped
    # <step>` and exits 0), so nothing writes to the QA ledger and its watermark holds still
    # between a rehearsal and the mint. The tick reads the marker before each step, so a tick
    # already running notices it too.
    #
    # The marker is one JSON file beside the stranded-mint record (`~/.claude/hecks-dev/quiesce`,
    # `HECKS_QUIESCE_STATE` moves it) holding its owner, reason and time. A marker older than the
    # staleness window (two hours) is ignored and reported, so a crashed mint cannot freeze QA
    # for good. It touches no ledger and no git state, and the mint itself never requires it.
    class QaQuiesceMarker
      # Raised when a hold or release is refused; the message is the reason.
      class Refused < RuntimeError; end

      # Where the marker lives.
      PATH = ENV.fetch("HECKS_QUIESCE_STATE", File.expand_path("~/.claude/hecks-dev/quiesce")).freeze

      # How long a marker holds before it counts as left behind by a crash.
      STALE_AFTER = Integer(ENV.fetch("HECKS_QUIESCE_STALE_SECONDS", 2 * 60 * 60))

      # What a marker says: who holds the window, why and since when.
      Hold = Struct.new(:owner, :reason, :held_at, keyword_init: true)

      # @param path [String] the marker file
      # @param stale_after [Integer] seconds after which a marker is ignored
      # @param clock [#call] answers the current Time
      def initialize(path: PATH, stale_after: STALE_AFTER, clock: -> { Time.now })
        @path = path
        @stale_after = stale_after
        @clock = clock
      end

      # @return [Hold, nil] the marker's content, fresh or stale, or nil when there is none
      def read
        return unless File.exist?(@path)

        data = JSON.parse(File.read(@path))
        Hold.new(owner: data["owner"].to_s, reason: data["reason"].to_s, held_at: Time.iso8601(data["held_at"]))
      rescue JSON::ParserError, ArgumentError, TypeError
        Hold.new(owner: "unknown", reason: "unreadable marker", held_at: File.mtime(@path))
      end

      # @return [Hold, nil] the marker when it is present and not stale
      def active
        hold = read
        hold if hold && !stale?(hold)
      end

      # @return [Hold, nil] the marker when it is present and past the staleness window
      def stale
        hold = read
        hold if hold && stale?(hold)
      end

      # Writes the marker. A fresh marker of another owner is refused unless forced; the same
      # owner's hold is refreshed, and a stale one is replaced.
      #
      # @return [Hold] what was written
      # @raise [Refused] when another owner holds a fresh marker and `force` is false
      def hold!(owner:, reason:, force: false)
        current = active
        if current && current.owner != owner && !force
          raise Refused, "already held by #{current.owner} (#{describe(current)}); release it, or hold with force"
        end

        write(Hold.new(owner: owner, reason: reason, held_at: @clock.call))
      end

      # Removes the marker. Another owner's fresh marker stays unless forced.
      #
      # @return [Hold, nil] the marker removed, or nil when there was none
      # @raise [Refused] when another owner holds a fresh marker and `force` is false
      def release!(owner:, force: false)
        current = read
        return unless current
        if current.owner != owner && !force && !stale?(current)
          raise Refused, "held by #{current.owner} (#{describe(current)}), not #{owner}; release with force to remove it"
        end

        FileUtils.rm_f(@path)
        current
      end

      # @return [String] a sentence on the marker: owner, reason and age, or that QA is not quiesced
      def status
        hold = read
        return "not quiesced: no marker at #{@path}" unless hold

        "#{stale?(hold) ? "stale (ignored)" : "quiesced"}: #{describe(hold)}"
      end

      # @return [String] "owner, reason, held 12 minutes ago"
      def describe(hold)
        "owner #{hold.owner}, reason #{hold.reason.inspect}, held #{age(hold)} ago (since #{hold.held_at.utc.iso8601})"
      end

      private

      def stale?(hold) = (@clock.call - hold.held_at) > @stale_after

      def age(hold)
        seconds = (@clock.call - hold.held_at).to_i
        return "#{seconds}s" if seconds < 120
        return "#{seconds / 60}m" if seconds < 7200

        "#{seconds / 3600}h"
      end

      def write(hold)
        FileUtils.mkdir_p(File.dirname(@path))
        temp = "#{@path}.#{Process.pid}"
        File.write(temp, JSON.generate(owner: hold.owner, reason: hold.reason, held_at: hold.held_at.utc.iso8601))
        File.rename(temp, @path)
        hold
      end
    end
  end
end
