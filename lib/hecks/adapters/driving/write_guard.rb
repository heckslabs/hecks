# frozen_string_literal: true

require_relative "context_line"
require_relative "../driven/worktree_overlay"

module Hecks
  module Adapters
    module Driving
      # Refuses a write from a linked worktree whose bluebook would store in Memory there while the
      # main checkout stores it elsewhere. It asks the same overlay question the worktree warning
      # asks (WorktreeOverlay.gap), and reads stores the way `hecks config` does, so the refusal
      # and the warning cannot disagree about what is missing.
      module WriteGuard
        module_function

        # @param directory [String] the checkout the command runs in
        # @param bluebook [String, nil] the bluebook the command belongs to
        # @param stores [#call] answers the store rows of a directory
        # @return [String, nil] the refusal, or nil when the write may proceed
        def refusal(directory, bluebook, stores: STORES)
          return unless bluebook

          main, files = WorktreeOverlay.gap(directory)
          return if files.empty?

          main_kind = kind_in(stores.call(main), bluebook)
          return if main_kind == ContextLine::MEMORY || main_kind == kind_in(stores.call(directory), bluebook)

          message(bluebook, main_kind, files)
        end

        # @param rows [Array<Array(String, String, String)>] store rows
        # @param bluebook [String]
        # @return [String] the kind of store the bluebook uses, Memory when it has none of its own
        def kind_in(rows, bluebook)
          row = rows.find { |label, _value, _source| label == "store #{bluebook}" }
          ContextLine.kind(row ? row[1] : ContextLine::MEMORY)
        end

        # @return [String] the refusal naming the bluebook, the store and the missing files
        def message(bluebook, main_kind, files)
          "hecks: refused: #{bluebook} stores in #{main_kind} in the main checkout, and this worktree " \
            "lacks #{files.join(", ")}, so the write would land in Memory here. " \
            "Run the command from the main checkout."
        end

        # Answers the store rows of a directory, through the adapter `hecks config` uses.
        STORES = ->(directory) { Hecks::Adapters::SettingsReading.new.stores(directory) }
      end
    end
  end
end
