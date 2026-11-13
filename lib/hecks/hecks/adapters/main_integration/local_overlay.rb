# frozen_string_literal: true

require "fileutils"
require_relative "kept_rows"

module Hecks
  module Adapters
    class MainIntegration
      # A checkout's machine-local overlay, written from the kept rows its copy needs (see
      # {KeptRows}). The train's copy and the development checkout each have one; neither is a hand
      # copy, so neither falls behind the rows. One hecksagon block is written per domain, each
      # binding that domain's rows, as the development checkout's overlay holds its Tickets and
      # Agents blocks beside the Hecks one.
      class LocalOverlay
        # Where the overlay is, relative to a checkout.
        PATH = File.join("lib", "hecks", "hecks", "hecks.local.hecksagon")

        # The store every kept row is bound to.
        ADAPTER = "SqlitePersistence"

        # The comment that opens the file.
        HEADER = <<~TEXT
          # Written by `LocalOverlay.write!` (and the push train at each boarding) from the KeptAggregate
          # rows of lib/hecks/hecks/hecks.bluebook. Gitignored; never committed, never edited.
        TEXT

        # Raised when there is nothing to write: an overlay with no binds would forget every record.
        class Empty < StandardError; end

        # @param root [String] the checkout
        # @param rows [Array<Hash>] the kept rows of every copy
        # @param copy [String] `main` or `train`
        def initialize(root, rows, copy)
          @root = root
          @rows = KeptRows.for_copy(rows, copy)
          @copy = copy
        end

        # @return [String] the overlay's path in the checkout
        def path = File.join(@root, PATH)

        # The overlay's text.
        #
        # @return [String]
        # @raise [Empty] when the copy keeps no row
        def text
          raise Empty, "no kept rows were read for the #{@copy} copy, so its overlay is left as it is" if @rows.empty?

          blocks = @rows.group_by { |row| row[:domain] }.map { |domain, rows| block(domain, rows) }
          [HEADER.chomp, *blocks, ""].join("\n")
        end

        # Writes the overlay when the checkout's differs.
        #
        # @return [String, nil] the path written, or nil when the checkout's was already this
        # @raise [Empty] when the copy keeps no row
        def write
          wanted = text
          return if File.file?(path) && File.read(path) == wanted

          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, wanted)
          path
        end

        private

        # The Hecks block keeps Memory as its root default; the other domains are attached and
        # inherit it, so their blocks bind only their rows.
        def block(domain, rows)
          root = domain == "Hecks" ? ["  persisted_by \"Memory\""] : []
          binds = rows.flat_map { |row| ["  # #{row[:reason]}", "  #{domain}::#{row[:aggregate]}.persisted_by(\"#{ADAPTER}\")"] }
          ["Hecks.hecksagon \"#{domain}\" do", *root, *binds, "end"].join("\n")
        end
      end
    end
  end
end
