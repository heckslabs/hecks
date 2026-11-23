# frozen_string_literal: true

require_relative "local_overlay"

module Hecks
  module Adapters
    class MainIntegration
      # Keeps the owner's checkout overlay in step with the `KeptAggregate` rows at each boarding,
      # so a row added to the list reaches the live store without a hand write. It refreshes an
      # overlay the primary checkout already has, never creates one, and never raises: a failure
      # is reported in the line it returns, so the boarding it rides is not held by it.
      class MainOverlay
        # @param checkout [String] the checkout the boarding runs from
        # @param rows [Array<Hash>] the kept rows of every copy
        def initialize(checkout, rows)
          @checkout = checkout.to_s
          @overlay = LocalOverlay.new(@checkout, rows, "main")
        end

        # @return [String] what was done, or why nothing was
        def refresh
          return "main overlay left: #{@checkout} is a linked worktree" unless primary?
          return "no overlay in #{@checkout}, none created" unless File.file?(@overlay.path)

          @overlay.write ? "wrote the main overlay #{LocalOverlay::PATH}" : "main overlay current"
        rescue LocalOverlay::Empty, SystemCallError => e
          "main overlay kept as it is: #{e.message}"
        end

        private

        def primary? = File.directory?(File.join(@checkout, ".git"))
      end
    end
  end
end
