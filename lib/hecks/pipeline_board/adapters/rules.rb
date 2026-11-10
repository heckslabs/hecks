# frozen_string_literal: true

require "hecks"
require_relative "boot_lock"

module Hecks
  module Adapters
    module PipelineBoard
      # The board's rules, read from the PipelineBoard bluebook's rows (`Verdict`, `Setting`,
      # `Finding`, `StaleStatus`, `ActionRule`, `CycleStage`). The adapters hold no rule of their
      # own: they hand this module what they read and it answers from the rows, so a change to a
      # rule is a change to `pipeline_board.bluebook`.
      #
      # Inside a booted domain the rows come from the registry's own PipelineBoard bluebook ({use}).
      # Standing alone, the bluebook beside these adapters is described once and kept.
      module Rules
        BLUEBOOK_DIR = File.expand_path("..", __dir__)
        TABLES = %w[Verdict Setting Finding StaleStatus ActionRule CycleStage].freeze

        module_function

        # Reads the rows from `registry`'s PipelineBoard bluebook when it holds one.
        #
        # @param registry [Runtime::Registry, nil]
        # @return [void]
        def use(registry)
          bluebook = registry.respond_to?(:bluebooks) ? registry.bluebooks["PipelineBoard"] : nil
          @tables = tables_of(bluebook) if bluebook
        end

        # @param name [String] a value object of the bluebook, such as `"Verdict"`
        # @return [Array<Hash{Symbol => Object}>] its declared rows, in the order they are written
        def rows(name) = tables.fetch(name)

        # The state a stage or tile is in, by its first rule that holds.
        #
        # @param stage [String] the `stage` of the `Verdict` rows
        # @param measures [Hash{Symbol => Numeric, nil}] what was read; nil is unreadable
        # @param limits [Hash{Symbol => Numeric}] numbers that outrank the `Setting` rows, such as
        #   the QualityControl world's push limits
        # @return [String] the state word, `unknown` when no rule holds
        def verdict(stage, measures, limits = {})
          rules = rows("Verdict").select { |row| row[:stage] == stage }.group_by { |row| row[:position] }
          held = rules.sort.map(&:last).find { |group| group.all? { |row| holds?(row, measures, limits) } }
          held ? held.first[:state] : "unknown"
        end

        # @param name [String, Symbol] a `Setting`
        # @param overrides [Hash{Symbol => Numeric}] declared values that replace the row's
        # @return [Numeric]
        def setting(name, overrides = {})
          overrides.fetch(name.to_sym) { rows("Setting").find { |row| row[:name] == name.to_s }.fetch(:value) }
        end

        # @return [Hash{Symbol => Integer}] the named settings, as the bluebook declares them
        def settings(*names) = names.to_h { |name| [name.to_sym, setting(name)] }

        # @return [Array<String>] what a Work item's landed-but-unfinished status may be
        def stale_statuses = rows("StaleStatus").map { |row| row[:status] }

        # @return [Array<String>] the kinds of finding the fan-out may flag
        def finding_kinds = rows("Finding").map { |row| row[:kind] }

        # @param action [String]
        # @return [Hash, nil] the `ActionRule` row, `needs` as symbols, `confirm` boolean
        def action(action)
          row = rows("ActionRule").find { |candidate| candidate[:action] == action }
          row&.merge(needs: row[:needs].split.map(&:to_sym), confirm: row[:confirm] == "yes")
        end

        def holds?(row, measures, limits)
          value = measures[row[:measure].to_sym]
          case row[:op]
          when "always" then true
          when "missing" then value.nil?
          else !value.nil? && value.public_send(row[:op], threshold(row, limits))
          end
        end

        def threshold(row, limits)
          bound = Float(row[:than], exception: false) || setting(row[:than], limits)
          bound * row[:scale]
        end

        def tables = (@tables ||= tables_of(described))

        def tables_of(bluebook)
          aggregate = bluebook.aggregates.find { |candidate| candidate.hecks_name == "PipelineBoard" }
          TABLES.to_h do |name|
            [name, aggregate.value_objects.find { |object| object.hecks_name == name }.members]
          end
        end

        def described
          registry = BootLock.exclusive(wait: BootLock::WAIT_SECONDS) { Hecks.describe(BLUEBOOK_DIR).registry }
          registry.bluebooks.fetch("PipelineBoard")
        end
      end
    end
  end
end
