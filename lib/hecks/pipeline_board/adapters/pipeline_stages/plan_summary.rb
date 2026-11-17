# frozen_string_literal: true

require_relative "plan_fold"
require_relative "plan_order"

module Hecks
  module Adapters
    module PipelineBoard
      # The planning page's summary, kept by the Tickets events instead of worked out from every open
      # Work item at each drawing: counts per lane, open and done counts per epic, the done total. An
      # event moves one item between counts, so a drawing reads the held counts and scans no item.
      # It holds a cursor per event source and applies only the events past it; a source that
      # shrank (a store that started over) starts the whole summary again from the first events.
      class PlanSummary
        Entry = Struct.new(:status, :priority, :epic)
        CLOSED = %w[done dropped].freeze

        def initialize = reset

        # @param source [Symbol] `:work` or `:epic`
        # @param events [Array<Runtime::Event>] every event of that source, oldest first
        # @return [PlanSummary] self, with the events past the cursor applied
        def catch_up(source, events)
          reset if events.size < @cursor[source]
          events[@cursor[source]..].each { |event| source == :work ? work(event) : epic(event) }
          @cursor[source] = events.size
          self
        end

        # @param running [Array<String>] the slugs of the Work items a session is running
        # @return [Hash] `done`, `open`, `epics` and `lanes`, as {PlanOrder.summary} answers
        def summary(running: [])
          lanes = @lanes.dup
          running.uniq.each { |slug| lanes = promoted(lanes, @items[slug]) }
          epics = @epic_open.count { |_, n| n.positive? }
          { done: @done, open: lanes.values.sum, epics: epics, lanes: lanes.merge("done" => @done) }
        end

        # @param limit [Integer] how many epics
        # @return [Array<Hash>] the first epics by title, each with `epic`, `title`, `open`, `done`
        def first_epics(limit)
          @titles.sort_by { |key, title| [title, key] }.first(limit).map do |key, title|
            { epic: key, title: title, open: @epic_open[key], done: @epic_done[key] }
          end
        end

        private

        def reset
          @cursor = Hash.new(0)
          @items = {}
          @lanes = PlanOrder::LANES.to_h { |lane| [lane, 0] }
          @epic_open = Hash.new(0)
          @epic_done = Hash.new(0)
          @titles = {}
          @done = 0
        end

        def work(event)
          slug = PlanFold.slug(event) or return
          entry = @items[slug]
          entry ? count(entry, -1) : (entry = @items[slug] = Entry.new("planned", "", ""))
          change(entry, event)
          count(entry, 1)
        end

        def change(entry, event)
          entry.status = PlanFold::STATUS.fetch(event.name.to_s, entry.status)
          entry.epic = PlanFold.read(event.payload, :epic) || entry.epic
          entry.priority = PlanFold.read(event.payload, :priority) || entry.priority
        end

        def epic(event)
          key = PlanFold.epic_key(event)
          title = PlanFold.read(event.payload, :title)
          @titles[key] = title if key && title && PlanFold::TITLED.include?(event.name.to_s)
        end

        def count(entry, sign)
          if CLOSED.include?(entry.status)
            return if entry.epic.empty?

            @epic_done[entry.epic] += sign
            @done += sign
          else
            @lanes[lane(entry)] += sign
            @epic_open[entry.epic] += sign unless entry.epic.empty?
          end
        end

        def lane(entry) = %w[now next later].include?(entry.priority) ? entry.priority : PlanOrder::UNSET

        def promoted(lanes, entry)
          return lanes if entry.nil? || CLOSED.include?(entry.status)

          lanes.merge(lane(entry) => lanes[lane(entry)] - 1, "running" => lanes["running"] + 1)
        end
      end
    end
  end
end
