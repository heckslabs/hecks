require "tempfile"

require_relative "lineage_manager/era_resolver"
require_relative "lineage_manager/minter"
require_relative "lineage_manager/merge_coordinator"
require_relative "lineage_manager/coverage_check"
require_relative "../../../runtime/era_guard"
require_relative "../../../runtime/registry"

module Hecksagain
  module Adapters
    class PostgresEra
      # The PostgresEra side of the boot-time era gate. Where every other
      # adapter's era check can only hold texts and refuse, this one
      # ACTS: a drifted shape whose translation edge exists, matches by
      # shape label, covers the whole diff, and passes the audit mints
      # the next era — one transaction — and boots into it. Everything
      # else refuses, as loudly and as specifically as the situation
      # allows, naming both authoring tools.
      #
      # Minting happens here, once: era identity (SHA-256 of the canonical
      # storage-shape serialization; the short prefix is the label edges
      # and refusals use) is computed at mint time and stored in
      # hecks_eras. Everything else reads stored names and never hashes
      # anything — an era name is a storage fact, minted on this path or
      # absent, never reconstructed.
      #
      # One concern per file under lineage_manager/: era_resolver (which
      # era is this boot?), minter (the mint path and its refusals),
      # merge_coordinator (bin/merge_tail's driver), coverage_check
      # (what a mint must prove first). What stays here is what they
      # share: the edge chain, and the shadow parse.
      module LineageManager
        extend EraResolver
        extend Minter
        extend MergeCoordinator
        extend CoverageCheck

        module_function

        # The FULL chain, one edge per step in original mint order —
        # never flattened. Each step is found by its stored labels;
        # every mint required its own edge, so a break in the chain is a
        # deleted file, and deserves its own refusal.
        def edge_chain(registry, bluebook, eras, current_label)
          labels = eras.map { |era| era[:label] } + [current_label]
          (0...(labels.size - 1)).map do |index|
            step = registry.translations.find do |t|
              t.domain == bluebook.name && t.from == labels[index] && t.to == labels[index + 1]
            end
            unless step
              raise Runtime::WiringError,
                    "cannot boot #{bluebook.name}: the edge chain is broken at era #{index + 1} — no translation " \
                    "leads #{labels[index]} to #{labels[index + 1]}; restore bluebook/translations/"
            end
            { translation: step }
          end
        end

        # Held texts live in rows, not files, but the predicate
        # extractor reads source from disk at the eval path — so a
        # shadow parse writes the text to a scratch file first.
        def shadow(source)
          file = Tempfile.new(["hecks-era-", ".bluebook"])
          file.write(source)
          file.flush
          Runtime::EraGuard.shadow_parse(source, file.path)
        ensure
          file&.close!
        end
      end
    end
  end
end
