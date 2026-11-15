# frozen_string_literal: true

require_relative "../landed_work"
require_relative "../branch_work_names"

module Hecks
  module Adapters
    class Dispatching
      # What a settle reads from the booted registry about a work item's landings: the commits its
      # branch landed as, when the work item last started, and its status. It is mixed into
      # {WorkItems}, whose `find` and `field` it uses, and it reads and never writes.
      #
      # A branch names its work item as {BranchWorkNames} reads it: the whole key, the key with QA's
      # prefix in front, or the key with `-N` after it when no work item carries that whole name.
      module LandingFacts
        # @param key [String] a Work item's key
        # @return [Array<String>] the commit of each landed `Landing` whose branch names the work
        #   item, empty when none did or the Hecks bluebook holds no Landing
        def landed_commits(key)
          aggregate = find("Delivery", "Landing")
          return [] unless aggregate && !key.to_s.empty?

          keys = work_keys
          landed = @registry.repository("Hecks", aggregate).all.select { |landing| landed_on?(landing, key.to_s, keys) }
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

        def landed_on?(landing, key, keys)
          return false unless field(landing, :status).to_s == "landed"

          BranchWorkNames.of(field(landing, :branch).to_s, keys).include?(key)
        end

        def work_keys
          work = find("Tickets", "Work")
          work ? @registry.repository("Tickets", work).all.map { |entry| field(entry, :work).to_s } : []
        end
      end
    end
  end
end
