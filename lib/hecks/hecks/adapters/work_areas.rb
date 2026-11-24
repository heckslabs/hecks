# frozen_string_literal: true

require_relative "area_overlap"
require_relative "area_names"
require_relative "started_work"
require_relative "wait_keys"
require_relative "console_capture"
require_relative "dispatching/shared_sections"

module Hecks
  module Adapters
    # The `WorkAreas` port's adapter for `Tickets::Work`: says whether a work item that was just
    # started
    # holds ground another started one already holds.
    #
    # It reads the other Work items from the registry it is built with and decides nothing about
    # the claim beyond the overlap rule in {AreaOverlap}; the bluebook sends a refused work item
    # back to
    # the plan. One with no area claims nothing and is never refused. A started work item that
    # holds other sections of a bluebook this one names by sections is no rival; the answer names
    # it and the file they share.
    class WorkAreas
      # The words a refusal puts between the work item and the path it cannot claim.
      REFUSED = "cannot claim"

      # @param registry [Runtime::Registry, nil] the booted registry whose Work items are read
      # @param aggregate [Object, nil] unused
      def initialize(registry: nil, aggregate: nil)
        @registry = registry
      end

      # Clears a started work item's area against every other started one's.
      #
      # @param held [Hash] the Work item: `work` and `area`
      # @return [Hash{Symbol => Hash}] `output:` the line that says the area is free, and names
      #   each started work item that shares a bluebook with it by sections
      # @raise [ConsoleCapture::Failure] naming the work item and the overlapping path
      def check_area(**held)
        key = plain(held[:work])
        mine = areas(held[:area])
        other, pair = mine.empty? ? nil : rival(key, mine)
        raise ConsoleCapture::Failure, "#{key} #{REFUSED} #{pair[0]}: #{other} holds #{pair[1]}" if other

        { output: { value: "#{key} holds #{mine.empty? ? "no area" : mine.join(", ")}#{sharers(key, mine)}" } }
      end

      # Clears a planned or rescoped work item's area against the checkout, while the Tickets
      # world's `area_names` switch is on.
      #
      # @param held [Hash] the Work item: `work` and `area`
      # @return [Hash{Symbol => Hash}] `output:` the line that says the area names the checkout
      # @raise [ConsoleCapture::Failure] naming the work item and every word that names nothing
      def check_names(**held)
        key = plain(held[:work])
        return { output: { value: "#{key}: area names are not checked" } } unless AreaNames.checked?(@registry)

        unnamed = AreaNames.unnamed(areas(held[:area]), root: AreaNames.root)
        raise ConsoleCapture::Failure, "#{key} area names nothing in the checkout: #{unnamed.join(", ")}" if unnamed.any?

        { output: { value: "#{key} area names the checkout" } }
      end

      # Checks that each key a work item waits on names a work item.
      #
      # @param held [Hash] the Work item: `work` and `waits_on`
      # @return [Hash{Symbol => Hash}] `output:` the line that says every key names a work item
      # @raise [ConsoleCapture::Failure] naming each key no work item has, and its nearest
      def check_wait_keys(**held)
        key = plain(held[:work])
        unknown = WaitKeys.unknown(@registry, held[:waits_on])
        raise ConsoleCapture::Failure, "#{key} waits on #{unknown.join("; ")}" if unknown.any?

        { output: { value: "#{key} waits on work items that exist" } }
      end

      private

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument

      def areas(list) = Array(list).map { |word| plain(word).to_s }.reject(&:empty?)

      def rival(key, mine)
        started.each do |item|
          next if item[:key] == key

          pair = AreaOverlap.first_overlap(mine, item[:area])
          return [item[:key], pair] if pair
        end
        nil
      end

      def sharers(key, mine)
        started.reject { |item| item[:key] == key }.flat_map do |item|
          Dispatching::SharedSections.between(mine, item[:area]).map do |share|
            "; shares #{share.path} with #{item[:key]} (#{share.theirs.join(", ")})"
          end
        end.join
      end

      def started
        StartedWork.items(@registry)
      end
    end
  end
end
