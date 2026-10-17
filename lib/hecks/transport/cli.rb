# frozen_string_literal: true

module Hecks
  # The clients adapters reach the outside world through, shared so each adapter adds only what
  # is particular to its service (ADR 0116).
  module Transport
    # The transport that runs another program: an argument list in, what it said out.
    #
    # The program runs in its own process group with its output going to files, never pipes, so
    # a timeout or an interrupt stops everything it started and a program that writes hundreds of
    # megabytes never blocks on a reader.
    module Cli
      # What a run may do to the world, narrowest first. A read-only client runs only `:reads`.
      EFFECTS = %i[reads writes executes_foreign_code].freeze

      # Nothing answered; a later run may.
      class Unavailable < StandardError; end

      # The program is not installed, or not on the `PATH` the run was given.
      class NotInstalled < Unavailable; end

      # The program ran past the client's timeout; its process group was stopped.
      class TimedOut < Unavailable; end

      # The client is read-only and the run is not a read. Nothing ran.
      class ReadOnly < StandardError; end
    end
  end
end

require_relative "cli/reply"
require_relative "cli/child"
require_relative "cli/client"
