# frozen_string_literal: true

require_relative "../landed_work"

module Hecks
  module Adapters
    class Dispatching
      # What a settle reads from the booted registry about a work item's landings: the commits its
      # branch landed as, when the work item last started, and its status. It is mixed into
      # {WorkItems}, whose `find` and `field` it uses, and it reads and never writes.
      #
      # A branch names its work item as {LandedWork} reads it: the whole key, or the key with QA's
      # prefix in front.
      module LandingFacts
        # @param key [String] a Work item's key
        # @return [Array<String>] the commit of each landed `Landing` whose branch names the work
        #   item, empty when none did or the Hecks bluebook holds no Landing
        def landed_commits(key)
          aggregate = find("Delivery", "Landing")
          return [] unless aggregate && !key.to_s.empty?

          branches = [key.to_s, "#{LandedWork::QA_PREFIX}#{key}"]
          landed = @registry.repository("Hecks", aggregate).all.select { |landing| landed_on?(landing, branches) }
          landed.map { |landing| field(landing, :landed).to_s }.reject(&:empty?)
        end

        # @param key [String] a Work item's key
        # @return [String] when the work item last started (its `claimed_at`), empty when the
        #   Tickets store holds no such item or it records no start
        def claimed_at(key)
          work = find("Tickets", "Work")
          return "" unless work

          record = work_record(work, key)
          record ? field(record, :claimed_at).to_s : ""
        end

        # @param key [String] a Work item's key
        # @return [String, nil] the work item's status, nil when the Tickets store holds no such
        #   item
        def status_of(key)
          work = find("Tickets", "Work")
          record = work && work_record(work, key)
          record && field(record, :status).to_s
        end

        private

        def work_record(work, key)
          @registry.repository("Tickets", work).all.find { |entry| field(entry, :work).to_s == key.to_s }
        end

        def landed_on?(landing, branches)
          field(landing, :status).to_s == "landed" && branches.include?(field(landing, :branch).to_s)
        end
      end
    end
  end
end
