# frozen_string_literal: true

require_relative "probe"

module Hecks
  module Adapters
    module PipelineBoard
      # Keeps each outside read for its reader's seconds, failures included, so neither a polling
      # page nor the board's own refresh can hammer `gh`, `git` or the disk. Each fetch forgets
      # the answers and failures older than the ttl, so it holds only what was asked within it,
      # however many keys a board asks.
      # Readers of one key take turns, so a key is read once however many ask; readers of
      # different keys never wait on each other, so one slow read holds up no other.
      class Cache
        # A cache that keeps answers for a reader's `ttl:` setting, else for the bluebook's
        # `Setting` row of that name.
        #
        # @param settings [Hash] the reader's settings
        # @param name [String] a `Setting` row, such as `"git_keep_seconds"`
        # @return [Cache]
        def self.kept(settings, name) = new(ttl: settings.fetch(:ttl) { -> { row(name) } })

        # @param name [String] a `Setting` row
        # @return [Numeric] its value; the rules are loaded when first asked, not with this file
        def self.row(name)
          require_relative "rules"
          Rules.setting(name)
        end

        # @param ttl [Numeric, #call] seconds an answer is kept, or what answers them when asked (a
        #   `Setting` row of the bluebook, read on first use and not when the reader is made)
        # @param clock [#call] the time in seconds; the monotonic clock when none is given
        def initialize(ttl: 20, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          @ttl = ttl
          @clock = clock
          @held = {}
          @turns = {}
          @lock = Mutex.new
        end

        # @param key [Object] what is read
        # @return [Object] the held answer while it is fresh, else the block's; a block that raises
        #   {Unavailable} is held as the failure and raised again until it expires
        def fetch(key, &block)
          kept = turn_of(key).synchronize { fresh_held(key) || hold(key, attempt(&block)) }
          kept.last.is_a?(Unavailable) ? raise(kept.last) : kept.last
        end

        # Forgets every held answer, so the next read asks again.
        # @return [void]
        def clear = @lock.synchronize { @held.clear }

        # @return [Integer] how many answers are held
        def size = @lock.synchronize { @held.size }

        private

        # The key's turn, made when none is held; a turn whose key is neither held nor being read
        # goes with the expired answers.
        def turn_of(key)
          @lock.synchronize do
            @held.select! { |_, kept| fresh?(kept) }
            @turns.select! { |name, turn| turn.locked? || @held.key?(name) }
            @turns[key] ||= Mutex.new
          end
        end

        def fresh_held(key)
          kept = @lock.synchronize { @held[key] }
          kept if kept && fresh?(kept)
        end

        def hold(key, value) = @lock.synchronize { @held[key] = [@clock.call, value] }

        def fresh?(kept) = @clock.call - kept.first < seconds

        def seconds = @seconds ||= @ttl.respond_to?(:call) ? @ttl.call : @ttl

        def attempt
          yield
        rescue Unavailable => e
          e
        end
      end
    end
  end
end
