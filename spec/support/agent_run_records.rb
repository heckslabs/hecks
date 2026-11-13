# frozen_string_literal: true

require "hecks/hecks/adapters/dispatching"
require_relative "registry_double"

# AgentRun records as a store lists them, and the {Hecks::Adapters::Dispatching::WorkItems} that
# reads them. A run key reused after its run ended keeps the ended record under `<key>~<n>`, with
# the same `run` field, so one key can be listed several times in any order.
module AgentRunRecords
  include RegistryDouble

  # A stored AgentRun record: its id, and the fields WorkItems reads.
  Record = Struct.new(:id, :run, :status, :condition, :started_at, keyword_init: true)

  # A loaded bluebook, as far as WorkItems looks: its aggregates by name.
  Shelf = Struct.new(:aggregates)

  # An aggregate, named as the bluebook names it.
  Named = Struct.new(:hecks_name)

  # A repository, as far as WorkItems reads it.
  Listing = Struct.new(:all)

  # @param id [String] the record's id: the run key itself for the record that holds it
  # @param status [String] the run's status
  # @param run [String] the run key the record is for
  # @return [Record] the record
  def run_record(id, status, run: "a")
    Record.new(id: id, run: run, status: status, condition: "done", started_at: "")
  end

  # @param records [Array<Record>] the AgentRun records, in the order the store lists them
  # @return [Hecks::Adapters::Dispatching::WorkItems] work items over a store holding them
  def work_items_over(*records)
    registry = registry_double(bluebook: Shelf.new([Named.new("AgentRun")]), repository: Listing.new(records))
    Hecks::Adapters::Dispatching::WorkItems.new(registry)
  end
end
