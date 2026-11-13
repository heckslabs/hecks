# frozen_string_literal: true

require_relative "context_line"
require_relative "../driven/worktree_overlay"
require "hecks/hecks/adapters/main_integration/kept_rows"

module Hecks
  module Adapters
    module Driving
      # The part of {WriteGuard} that reads the kept rows: a checkout that has opted into
      # persistence (it holds a local overlay) but binds a kept aggregate to Memory would forget
      # that aggregate's record by the next command, so the write is refused by the aggregate's
      # name and the command that writes the overlay. A checkout with no local overlay is in
      # Memory by choice (a fresh clone, CI, a client: ADR 0136) and is let through, and so is a
      # process that asks for Memory with `HECKS_ENVIRONMENT=memory`.
      class KeptCheck
        # The overlay whose presence says a checkout has opted into persistence.
        OVERLAY = "lib/hecks/hecks/hecks.local.hecksagon"

        # @param rows [Array<Hash>] the kept rows, as `KeptRows.from_registry` reads them
        # @param stores [#call] answers the store rows of a checkout root
        # @param env [#[]] where `HECKS_ENVIRONMENT` is read
        def initialize(rows, stores, env)
          @rows = rows
          @stores = stores
          @env = env
        end

        # @param directory [String] the directory the command runs in
        # @param bluebook [String, nil] the command's bluebook
        # @param aggregate [String, nil] the command's aggregate
        # @return [String, nil] the refusal, or nil when the write is kept or need not be
        def refusal(directory, bluebook, aggregate)
          root = opted_in_root(directory)
          row = root && kept_row(root, bluebook, aggregate)
          return unless row && memory?(root, bluebook, aggregate)

          message(root, row)
        end

        private

        def opted_in_root(directory)
          return if @env["HECKS_ENVIRONMENT"].to_s == "memory"

          root = WorktreeOverlay.ascend_to_git(File.expand_path(directory))
          root if root && File.file?(File.join(root, OVERLAY))
        end

        def kept_row(root, bluebook, aggregate)
          rows = MainIntegration::KeptRows.for_copy(@rows, MainIntegration::KeptRows.copy_of(root))
          MainIntegration::KeptRows.find(rows, bluebook, aggregate)
        end

        def memory?(root, bluebook, aggregate)
          WriteGuard.kind_in(@stores.call(root), bluebook, aggregate) == ContextLine::MEMORY
        end

        def message(root, row)
          copy = MainIntegration::KeptRows.copy_of(root)
          "hecks: refused: #{row[:domain]}::#{row[:aggregate]} is kept across processes (#{row[:reason]}), but this " \
            "checkout binds it to Memory, so the next command would forget it. Write the overlay with " \
            "`exe/hecks LocalOverlay.write! root.value=#{root} copy.value=#{copy}`."
        end
      end
    end
  end
end
