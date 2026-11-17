# frozen_string_literal: true

require "hecks/hecks/adapters/codebase/heavy_slots"

module Hecks
  module Adapters
    class StallWatching
      # The `slots` evidence read: who holds each heavy-job slot and how long ago each slot's lock
      # last changed hands, so a landing that only waits its turn shows it. A slot's file is
      # rewritten whenever a job takes or frees the slot, so its modification time is that moment.
      # It reads the slot files and changes nothing.
      class SlotEvidence
        # @param dir [String] the directory the slots live in, the machine's own when absent
        # @param now [Time] the clock's answer, for a spec
        def initialize(dir: Codebase::HeavySlots.directory, now: Time.now)
          @dir = dir
          @now = now
        end

        # @return [String, nil] one line naming each slot's holder and the minutes since it changed
        #   hands; nil when the machine keeps no slot
        def line
          files = Dir.glob(File.join(@dir, "slot-*.lock"))
          return if files.empty?

          "Heavy-job slots: #{files.map { |file| slot(file) }.join(", ")}"
        end

        private

        def slot(file)
          text = File.read(file).strip
          "#{File.basename(file, ".lock")} #{text.empty? ? "free" : "held by #{text}"}, changed #{minutes(file)} min ago"
        rescue SystemCallError
          "#{File.basename(file, ".lock")} unreadable"
        end

        def minutes(file) = [((@now - File.mtime(file)) / 60).to_i, 0].max
      end
    end
  end
end
