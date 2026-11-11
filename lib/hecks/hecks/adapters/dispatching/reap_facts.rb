# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # What the mechanical cleanup of finished sessions reads from the booted registry: a Work
      # item's status, the roles whose runs leave no product, and every run's ledger row. It is
      # mixed into {WorkItems}, whose `find` and `field` it uses, and it reads and never writes.
      module ReapFacts
        # @param key [String] a Work item's key
        # @return [String] the Work item's status (`planned`, `started`, `done`, `dropped`), empty
        #   when the Tickets store holds no such item
        def work_status(key)
          work = find("Tickets", "Work")
          return "" unless work && !key.to_s.empty?

          record = @registry.repository("Tickets", work).all.find { |entry| field(entry, :work).to_s == key.to_s }
          record ? field(record, :status).to_s : ""
        end

        # @return [Array<String>] the roles the Agents bluebook's `NoProductRole` rows name, whose
        #   runs leave no Work product to land, or empty when that bluebook is not loaded
        def no_product_roles
          rows = find("Agents", "Role")&.value_objects&.find { |object| object.hecks_name == "NoProductRole" }
          Array(rows&.members).map { |row| row[:role].to_s }
        end

        # @return [Array<Hash>] each agent run as `run:`, `session:`, `status:`, `tidied_at:`,
        #   `detail:` and `refusal:`, a tidied run included, for the report of a reap
        def run_records
          aggregate = find("Hecks", "AgentRun")
          return [] unless aggregate

          @registry.repository("Hecks", aggregate).all.map do |run|
            %i[run session status tidied_at detail refusal].to_h { |name| [name, field(run, name).to_s] }
          end
        end
      end
    end
  end
end
