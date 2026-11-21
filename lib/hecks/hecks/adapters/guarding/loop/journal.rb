# frozen_string_literal: true

require "fileutils"
require "json"

module Hecks
  module Adapters
    class Guarding
      module Loop
        # The loop's record of what it saw and did: one JSON line each, appended under its home
        # directory. The domain is never booted to write it; a person or a later read takes it up.
        class Journal
          # @param home [String] the loop's directory
          # @param clock [#call] seconds since the epoch
          def initialize(home, clock)
            @path = File.join(home, "journal.jsonl")
            @clock = clock
          end

          # @param kind [String] what happened, such as `resumed` or `loops_missing`
          # @param session [String] the pinned session it is about, or empty
          # @param detail [Hash] the facts that go with it
          # @return [void]
          def add(kind, session = "", **detail)
            FileUtils.mkdir_p(File.dirname(@path))
            line = JSON.generate(at: @clock.call, kind: kind, session: session, detail: detail)
            File.open(@path, "a") { |file| file.puts(line) }
          end
        end
      end
    end
  end
end
