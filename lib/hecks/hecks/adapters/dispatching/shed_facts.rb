# frozen_string_literal: true

require_relative "../landed_work"

module Hecks
  module Adapters
    class Dispatching
      # What a look for the work item to shed reads from the booted registry: the rows that say
      # which started item may be asked to yield, the branches a landing still holds, and the
      # yield kinds a fill restarts first. It is mixed into {WorkItems}, whose `find` and `field`
      # it uses, and it reads and never writes.
      module ShedFacts
        # @return [Hash{String => Integer}] each priority a started item may be shed at with its
        #   rank, from the Delegate bluebook's `ShedTier` rows; empty when none is declared
        def shed_tiers = rows_of("Hecks", "Shed", "ShedTier").to_h { |row| [row[:priority].to_s, row[:rank].to_i] }

        # @return [Array<String>] the holds that keep a started item from being shed, from the
        #   Delegate bluebook's `ShedHold` rows
        def shed_holds = rows_of("Hecks", "Shed", "ShedHold").map { |row| row[:hold].to_s }

        # @return [Array<String>] the yield kinds a fill restarts ahead of the plan, from the
        #   Tickets bluebook's `YieldKind` rows
        def first_kinds
          rows_of("Tickets", "Work", "YieldKind").select { |row| row[:first] == true }.map { |row| row[:kind].to_s }
        end

        # @return [Array<String>] the Work item of each branch a `Landing` was asked for and has
        #   not settled, so its landing or boarding may hold the line
        def landing_work
          aggregate = find("Delivery", "Landing")
          return [] unless aggregate

          open = @registry.repository("Hecks", aggregate).all.select { |landing| field(landing, :status).to_s == "requested" }
          open.map { |landing| field(landing, :branch).to_s.delete_prefix(LandedWork::QA_PREFIX) }
        end

        private

        # Whether a run waits on its plan review, and whether it was asked to yield.
        def flags(run) = { reviewing: field(run, :reviewing) == true, shedding: field(run, :shedding) == true }

        def rows_of(domain, aggregate, name)
          Array(find(domain, aggregate)&.value_objects&.find { |object| object.hecks_name == name }&.members)
        end
      end
    end
  end
end
