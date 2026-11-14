# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # The facts a look for the work item to shed answers: how many coders run, how many of them
      # were already asked to yield, and the first started item the bluebook's rows allow. The
      # rows are the rule (`ShedTier`: the priorities and their rank; `ShedHold`: what keeps an
      # item); this only reports which hold for each item and applies them. It asks nobody.
      class ShedSurvey
        # @param work_items [#started, #runs, #shed_tiers, #shed_holds, #landing_work] the listing
        # @param red [#call] answers whether a work item is the fix of a red main
        def initialize(work_items, red:)
          @work_items = work_items
          @red = red
        end

        # @return [Hash{Symbol => Object}] `coders:` the started items whose run is started,
        #   `shedding:` how many of those runs were asked to yield, and `candidate:` the key of the
        #   item to ask, empty when the rows allow none
        def to_h = { coders: coders.size, shedding: coders.count { |item| shedding?(item) }, candidate: candidate }

        # @param item [Plan::Item] a started work item
        # @return [Array<String>] the holds that are true of it: `red`, `review`, `landing`
        def holds_of(item)
          facts = { "red" => @red.call(item), "review" => run(item)[:reviewing] == true, "landing" => landing.include?(item.key) }
          facts.select { |_hold, held| held }.keys
        end

        private

        # The lowest rank, and among equals the run started last.
        def candidate
          newest_first = allowed.sort_by { |item| run(item)[:started_at].to_s }.reverse
          newest_first.min_by { |item| tiers[item.priority.to_s] }&.key.to_s
        end

        def allowed
          kept = @work_items.shed_holds
          coders.select { |item| tiers.key?(item.priority.to_s) && !shedding?(item) && !holds_of(item).intersect?(kept) }
        end

        def coders = (@coders ||= @work_items.started.select { |item| run(item)[:status].to_s == "started" })

        def shedding?(item) = run(item)[:shedding] == true

        def run(item) = runs.fetch(item.key, {})

        def runs = (@runs ||= @work_items.runs)

        def tiers = (@tiers ||= @work_items.shed_tiers)

        def landing = (@landing ||= @work_items.landing_work)
      end
    end
  end
end
