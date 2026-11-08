# frozen_string_literal: true

require "json"
require "time"
require "fileutils"

module Hecks
  module Adapters
    # The marker that holds local main for a boarding: a JSON file in the repository's common git
    # directory, so every worktree sees one hold and a spec's temporary repository never sees the
    # owner's. It names the commit rehearsed, the owner, the reason and the time. The marker only
    # reports; the caller passes the window, so a hold older than it counts as left behind by a
    # crash and is ignored.
    class BoardingHoldMarker
      # The marker's file name, in the common git directory.
      FILE = "hecks-boarding-hold.json"

      # The minutes a hold lasts when no world setting names another.
      DEFAULT_MINUTES = 20

      # What a marker says: the commit, who holds it, why, and since when.
      Hold = Struct.new(:boarding, :owner, :reason, :held_at, keyword_init: true)

      # @param git_dir [String] the repository's common git directory
      # @param minutes [Numeric] the window a hold lasts
      # @param clock [#call] answers the current Time
      def initialize(git_dir, minutes: DEFAULT_MINUTES, clock: -> { Time.now })
        @path = File.join(git_dir, FILE)
        @window = minutes.to_f * 60
        @clock = clock
      end

      # @return [Hold, nil] the hold, fresh or expired, or nil when there is none
      def read
        return unless File.exist?(@path)

        data = JSON.parse(File.read(@path))
        Hold.new(boarding: data["boarding"].to_s, owner: data["owner"].to_s, reason: data["reason"].to_s,
                 held_at: Time.iso8601(data["held_at"]))
      rescue JSON::ParserError, ArgumentError, TypeError
        Hold.new(boarding: "unknown", owner: "unknown", reason: "unreadable marker", held_at: File.mtime(@path))
      end

      # @return [Hold, nil] the hold when it is present and inside its window
      def active
        hold = read
        hold if hold && !expired?(hold)
      end

      # Writes the hold, replacing any earlier one.
      #
      # @param boarding [String] the commit the hold is named for
      # @param owner [String] who holds
      # @param reason [String] why
      # @return [Hold] what was written
      def hold!(boarding:, owner:, reason:)
        hold = Hold.new(boarding: boarding, owner: owner, reason: reason, held_at: @clock.call)
        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, JSON.generate(hold.to_h.merge(held_at: hold.held_at.utc.iso8601)))
        hold
      end

      # Removes the hold, expired or not.
      #
      # @return [Hold, nil] the hold removed, or nil when there was none
      def release!
        hold = read
        FileUtils.rm_f(@path)
        hold
      end

      # @param hold [Hold] the hold a landing ran into
      # @return [String] the refusal a landing is given, naming the commit and the owner
      def refusal(hold)
        "main is frozen for boarding #{hold.boarding[0, 9]} by #{hold.owner}: retry after release " \
          "(held #{age(hold)} ago; a hold ends after #{(@window / 60).round} minutes)"
      end

      # @return [String] a sentence on the hold: commit, owner, reason and age, or that none stands
      def status
        hold = read
        return "not held: no boarding hold at #{@path}" unless hold

        "#{expired?(hold) ? "expired (ignored)" : "held"}: boarding #{hold.boarding[0, 9]}, owner #{hold.owner}, " \
          "reason #{hold.reason.inspect}, held #{age(hold)} ago"
      end

      private

      def expired?(hold) = (@clock.call - hold.held_at) > @window

      def age(hold)
        seconds = (@clock.call - hold.held_at).to_i
        seconds < 120 ? "#{seconds}s" : "#{seconds / 60}m"
      end
    end
  end
end
