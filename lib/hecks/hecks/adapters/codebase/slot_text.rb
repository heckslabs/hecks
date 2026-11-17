# frozen_string_literal: true

module Hecks
  module Adapters
    module Codebase
      # What a heavy-job place's file says: its holder's job and pid while the job runs, and
      # nothing once the job has ended.
      module SlotText
        # Empties a place's text while its lock is still held, so the pid of an ended holder is
        # never read as a holder and a next holder's text is never erased, then closes the place.
        #
        # @param place [File] an open place the caller holds the lock of
        # @return [void]
        def self.release(place)
          place.truncate(0)
        rescue SystemCallError, IOError
          nil
        ensure
          place.close
        end

        # @param job [String] the waiting job's class
        # @param dir [String] the directory the places live in
        # @param cap [Integer] how many places there are
        # @return [String] the line that says the job waits, and for whom
        def self.waiting_line(job, dir, cap)
          "hecks: #{job} waiting for a heavy-job slot, #{cap} of #{cap} taken (#{holders(dir, cap).join(", ")})"
        end

        # @param dir [String] the directory the places live in
        # @param cap [Integer] how many places there are
        # @return [Array<String>] what each place's file names: the job's class and its pid
        def self.holders(dir, cap)
          (0...cap).map { |index| File.read(File.join(dir, "slot-#{index}.lock")).strip }.reject(&:empty?)
        rescue SystemCallError
          []
        end
      end
    end
  end
end
