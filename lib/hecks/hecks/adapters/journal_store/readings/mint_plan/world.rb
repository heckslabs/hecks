# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    class JournalStore
      module Readings
        module MintPlan
          # What the world around a store says about a mint: the flags its world declares, the
          # marker a stranded landing leaves (`MainMaintenance` refuses every mint while it stands)
          # and the marker another agent leaves to quiesce the ledger. Only files and settings are
          # read.
          class World
            # @param held [HeldDomain] the loaded domain
            # @param dev_dir [String, nil] where the markers live; `HECKS_DEV_STATE`, else
            #   `~/.claude/hecks-dev`
            def initialize(held, dev_dir: nil)
              @held = held
              @dev_dir = dev_dir || ENV.fetch("HECKS_DEV_STATE", File.expand_path("~/.claude/hecks-dev"))
            end

            # @return [Boolean] whether the world declares `disposable_ledger true`
            def disposable?
              PostgresRevision::LineageManager::DisposableLedger.declared?(@held.settings)
            end

            # @return [String] the flags, in words
            def flags
              "bound to #{@held.adapter_name}; mint_eras=#{setting(:mint_eras)}; " \
                "disposable_ledger=#{setting(:disposable_ledger)}"
            end

            # @return [Boolean] whether the world lets a copy mint
            def mint_eras? = [true, "true"].include?(setting(:mint_eras, false))

            # @return [Array(Symbol, String)] refuse while a stranded landing stands
            def stranded
              return [:pass, "no stranded landing (#{stranded_path})"] unless File.exist?(stranded_path)

              [:refuse, "mints are refused until the stranded landing is resolved: #{File.read(stranded_path).strip}"]
            end

            # @return [Array(Symbol, String)] the quiesce markers that stand, if any
            def quiesce
              found = Dir.glob([File.join(@dev_dir, "quiesce"), File.join(@dev_dir, "qa_quiesce.*")])
              return [:info, "no quiesce marker in #{@dev_dir}"] if found.empty?

              [:info, "quiesced by another agent: #{found.join(", ")}"]
            end

            private

            def setting(key, default = "unset")
              PostgresRevision.setting(@held.settings, key, default: default)
            end

            def stranded_path
              File.join(ENV.fetch("HECKS_MINT_STATE", File.join(@dev_dir, "mint")), "stranded.json")
            end
          end
        end
      end
    end
  end
end
