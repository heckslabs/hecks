# frozen_string_literal: true

require "hecks/hecks/adapters/started_work"

module Hecks
  module Adapters
    # What the registered hand runs hold: the one read every reap consults before it removes a
    # session or retires a worktree. A hand run is held while its registration is recorded and not
    # ended, under its own run key; a replaced registration, archived as `<run>~<n>`, holds nothing.
    # It only reads the `HandRun` rows of the Agents bluebook; a boot with none holds nothing.
    class HandRunHold
      # @param registry [Runtime::Registry, nil] whose Agents bluebook holds the `HandRun` rows
      # @param held [#call, nil] stand-in answering the held rows (`run:`, `session:`, `checkout:`)
      def initialize(registry: nil, held: nil)
        @registry = registry
        @held = held
      end

      # @param id [String] a session's id, short or full
      # @return [String, nil] the run key of the hand run holding the session, nil when none does
      def session(id)
        id = id.to_s
        return nil if id.empty?

        rows.find { |row| same_session?(row[:session], id) }&.fetch(:run)
      end

      # @param path [String] a worktree's path
      # @return [String, nil] the run key of the hand run whose checkout is the path or inside it
      def checkout(path)
        path = path.to_s
        return nil if path.empty?

        rows.find { |row| within?(row[:checkout], path) }&.fetch(:run)
      end

      # @return [Array<Hash{Symbol => String}>] each held hand run: `run:`, `session:`, `checkout:`
      def rows = @held ? @held.call : read

      private

      def same_session?(held, id) = !held.empty? && (held.start_with?(id) || id.start_with?(held))

      def within?(checkout, path) = !checkout.empty? && (checkout == path || checkout.start_with?("#{path}/"))

      def read
        aggregate = hand_run
        return [] unless aggregate

        @registry.repository("Agents", aggregate).all.filter_map { |record| held(record) }
      end

      def held(record)
        run = StartedWork.value(record, :run).to_s
        return if archived?(record) || StartedWork.value(record, :status).to_s != "registered"

        { run: run, session: StartedWork.value(record, :session).to_s,
          checkout: StartedWork.value(record, :checkout).to_s }
      end

      # An archived registration keeps its fields but is stored under `<run>~<n>`.
      def archived?(record) = record.respond_to?(:id) && record.id.to_s.include?("~")

      def hand_run
        bluebook = @registry&.bluebook("Agents")
        bluebook&.aggregates&.find { |candidate| candidate.hecks_name == "HandRun" }
      end
    end
  end
end
