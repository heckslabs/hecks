# frozen_string_literal: true

require "hecks/hecks/adapters/area_overlap"
require "hecks/hecks/adapters/dispatching/plan"
require "hecks/hecks/adapters/dispatching/shared_sections"

module Hecks
  module Adapters
    class WorkShow
      # The started work items whose claimed area meets one work item's area, each with the pair
      # of paths {AreaOverlap} found, read against this checkout's root as the dispatch plan does,
      # and those that share a bluebook with it by different sections
      # ({Dispatching::SharedSections}).
      class Overlaps
        # @param started [Array<Hash>] the started work items, as {StartedWork.items} reads them
        def initialize(started)
          @started = started
        end

        # @param key [String] the work item asked about, left out of its own overlaps
        # @param area [Array<String>] the area it claims
        # @return [Array<Hash>] `with:`, `mine:`, `theirs:` of each started work item that meets it
        def of(key, area)
          @started.reject { |item| item[:key] == key }.filter_map do |item|
            pair = AreaOverlap.first_overlap(area, item[:area], root: Dispatching::Plan::REPOSITORY)
            { with: item[:key], mine: pair[0], theirs: pair[1] } if pair
          end
        end

        # @param key [String] the work item asked about, left out of its own shares
        # @param area [Array<String>] the area it claims
        # @return [Array<Hash>] `with:`, `path:`, `theirs:` for each bluebook a started work item
        #   shares with it by sections, `theirs` the sections that item holds
        def shares(key, area)
          @started.reject { |item| item[:key] == key }.flat_map do |item|
            Dispatching::SharedSections.between(area, item[:area], root: Dispatching::Plan::REPOSITORY)
                                       .map { |share| { with: item[:key], path: share.path, theirs: share.theirs } }
          end
        end
      end
    end
  end
end
