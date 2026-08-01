require "tempfile"

module Hecksagain
  module Adapters
    class Postgres
      # The Postgres side of the boot-time era gate. Where every other
      # adapter's era check can only hold texts and refuse, this one
      # ACTS: a drifted shape whose translation edge exists, matches by
      # shape label, covers the whole diff, and passes the audit mints
      # the next era — one transaction — and boots into it. Everything
      # else refuses, as loudly and as specifically as the situation
      # allows, naming both authoring tools.
      #
      # Minting is Ruby-only: era identity (SHA-256 of the canonical
      # storage-shape serialization; the short prefix is the label edges
      # and refusals use) is computed here, once, and stored in
      # hecks_eras. The Rust runtime reads stored names and never hashes
      # anything — a Rust boot that finds an unminted era refuses toward
      # this side.
      module LineageManager
        module_function

        def check!(registry:, bluebook:, current_text:, settings:, directory: nil)
          db = Postgres.connect_for(bluebook.name, settings)
          lineage = Lineage.new(db, bluebook.name)
          lineage.ensure_base!

          held = lineage.eras
          if held.empty?
            lineage.hold_first!(current_text, projection: Runtime::StorageShape.project(bluebook))
            bluebook.aggregates.each { |aggregate| lineage.ensure_first_head!(aggregate.storage_name) }
            return
          end

          current_shape = Runtime::StorageShape.project(bluebook)
          shapes = held.map { |era| [era, Runtime::StorageShape.project(shadow(era[:held_text]))] }

          latest, latest_shape = shapes.last
          if latest_shape == current_shape
            bluebook.aggregates.each { |aggregate| lineage.ensure_first_head!(aggregate.storage_name) } if latest[:ordinal] == 1
            registry.resolved_eras[bluebook.name] = latest[:ordinal]
            return
          end

          matched, = shapes.find { |_, shape| shape == current_shape }
          if matched
            # A held-but-superseded era — an old checkout still running.
            # Permitted, on Postgres alone: the old world keeps booting
            # its era and writing its own partition under its own
            # grants; the new head's watermark already excludes those
            # post-cut writes, and the divergence stays observable until
            # a deliberate tail-merge.
            registry.resolved_eras[bluebook.name] = matched[:ordinal]
            return
          end

          registry.resolved_eras[bluebook.name] =
            mint!(registry, bluebook, current_text, lineage, latest,
                  role: settings[:role] || settings["role"], directory: directory)
        ensure
          db&.close
        end

        def mint!(registry, bluebook, current_text, lineage, latest, role: nil, directory: nil)
          ensure_named!(lineage, latest)
          latest = lineage.eras.last

          hash = Runtime::StorageShape.mint_hash(bluebook)
          label = hash[0, Runtime::StorageShape::LABEL_LENGTH]
          ordinal = latest[:ordinal] + 1

          edges = registry.translations.select { |t| t.domain == bluebook.name && t.from == latest[:label] }
          if edges.empty?
            refuse_toward_the_scaffold!(registry, bluebook, lineage, latest, ordinal, directory)
          end
          if edges.size > 1
            raise Runtime::WiringError,
                  "cannot boot #{bluebook.name}: #{edges.size} translation edges leave era #{latest[:ordinal]} " \
                  "(#{latest[:label]}) — eras fork mechanically; keep one edge per source shape"
          end

          edge = edges.first
          unless edge.to == label
            raise Runtime::WiringError,
                  "cannot boot #{bluebook.name}: the translation edge from #{latest[:label]} targets " \
                  "#{edge.to}, but the current shape is #{label} — the edge is stale; re-run bin/scaffold_translation"
          end

          # A compute's only verification is the audit's human-approved
          # sample — mint stays non-interactive by requiring the
          # approval to already exist, recorded IN THIS DATABASE by
          # `bin/translation_audit … --approve` and bound to what was
          # actually reviewed: this edge's parsed content, and the
          # journal as it stood when the samples were read. A journal
          # that has advanced past the review invalidates it — the
          # approved samples no longer cover the data.
          if edge.aggregates.any? { |declared| !declared.computes.empty? }
            approval = lineage.approval_for(from: edge.from, to: edge.to)
            unless approval && approval[:edge_digest] == Translation::Audit.edge_digest(edge)
              raise Runtime::WiringError,
                    "cannot mint era #{ordinal} of #{bluebook.name}: this edge carries a compute rule, and " \
                    "the audit's human-approved sample is a compute's only verification — run " \
                    "bin/translation_audit with --approve, then boot again"
            end
            tip = lineage.last_ordinal
            if approval[:reviewed_ordinal] != tip
              raise Runtime::WiringError,
                    "cannot mint era #{ordinal} of #{bluebook.name}: the journal advanced past the approved " \
                    "review (ordinal #{approval[:reviewed_ordinal]} reviewed, #{tip} now) — the samples a " \
                    "human approved no longer cover the data; re-run bin/translation_audit with --approve"
            end
          end

          check_coverage!(registry, bluebook, shadow(latest[:held_text]), edge)

          chain = edge_chain(registry, bluebook, lineage.eras, label)
          audit!(bluebook, lineage, chain, ordinal, edge)
          lineage.mint_era!(
            ordinal: ordinal, hash: hash, label: label, held_text: current_text,
            aggregates: bluebook.aggregates, edges: chain, role: role,
            projection: Runtime::StorageShape.project(bluebook)
          )
          ordinal
        end

        # No edge yet: the boot refuses toward the authoring loop —
        # naming both tools and the era ordinal. With HECKS_SCAFFOLD=1
        # the boot RUNS the scaffold first (an explicit flag, never a
        # silent side-effect) and the refusal names the file it wrote.
        def refuse_toward_the_scaffold!(registry, bluebook, lineage, latest, ordinal, directory)
          if ENV["HECKS_SCAFFOLD"] == "1" && directory
            path = scaffold!(registry, bluebook, lineage, latest, directory)
            raise Runtime::WiringError,
                  "cannot boot #{bluebook.name}: the shape changed (era #{ordinal}) — wrote #{path}; " \
                  "review it (resolve every unresolved), check it with bin/translation_audit, then boot again"
          end

          raise Runtime::WiringError,
                "cannot boot #{bluebook.name}: the shape changed (era #{ordinal}) and no translation edge " \
                "covers it — run bin/scaffold_translation to write the edge, " \
                "check it with bin/translation_audit, then boot again"
        end

        # Diff the held era against the current shape and write the edge
        # file — confident rules inline, ambiguities as parse-refusing
        # `unresolved` lines. Returns the file path.
        def scaffold!(registry, bluebook, lineage, latest, directory)
          ensure_named!(lineage, latest)
          latest = lineage.eras.last

          hash = Runtime::StorageShape.mint_hash(bluebook)
          held_bluebook = shadow(latest[:held_text])
          diffed = Translation::Scaffold.diff(held_bluebook, bluebook)
          edge = Translation::Scaffold::Edge.new(
            domain: bluebook.name,
            from: latest[:label],
            to: hash[0, Runtime::StorageShape::LABEL_LENGTH],
            ordinal: latest[:ordinal] + 1,
            label: hash[0, Runtime::StorageShape::LABEL_LENGTH],
            aggregates: diffed[:aggregates],
            retired: diffed[:retired]
          )
          Translation::Scaffold.write!(directory, edge)
        end

        # Tail-merge, driven from bin/merge_tail: interleave the old
        # world's post-cut writes into the head by their recorded global
        # ordinals, under the full audit, in one transaction.
        def merge!(registry:, bluebook:, settings:, winners: {})
          db = Postgres.connect_for(bluebook.name, settings)
          lineage = Lineage.new(db, bluebook.name)
          lineage.ensure_base!

          held = lineage.eras
          raise Runtime::WiringError, "nothing to merge — #{bluebook.name} stands at era 1" if held.size < 2

          latest = held.last
          chain = edge_chain(registry, bluebook, held[0..-2], latest[:label])

          audit = lambda do
            violations = []
            bluebook.aggregates.each do |aggregate|
              rows = db.exec("SELECT id, state FROM #{PG::Connection.quote_ident(lineage.head_view(aggregate.storage_name))}")
                       .to_h { |row| [row["id"], JSON.parse(row["state"])] }
              verdict = Translation::Audit.check(aggregate: aggregate, declared: nil, before: rows, after: rows)
              violations.concat(verdict.violations)
            end
            violations
          end

          lineage.merge_tail!(aggregates: bluebook.aggregates, edges: chain, winners: winners, audit: audit)
        ensure
          db&.close
        end

        # Era names are minted once. An era held before any drift was
        # seen has no name yet; it gets one the moment an edge needs to
        # leave it.
        def ensure_named!(lineage, era)
          return if era[:hash]

          held_bluebook = shadow(era[:held_text])
          hash = Runtime::StorageShape.mint_hash(held_bluebook)
          lineage.mint_name!(era[:ordinal], hash, hash[0, Runtime::StorageShape::LABEL_LENGTH])
        end

        # Layer 1 against THIS edge specifically: every vanished or
        # retyped path in the held→current diff must be explained, and
        # every held aggregate must still be claimed. The refusal is
        # EraGuard's own, byte for byte.
        def check_coverage!(registry, bluebook, held_bluebook, edge)
          bluebook.aggregates.each do |aggregate|
            rules = Ports::Persistence::Lineage.from_declared(edge.for_aggregate(aggregate.name), aggregate.name)
            held_aggregate = held_bluebook.aggregate(rules&.ancestor_name || aggregate.name)
            next unless held_aggregate

            check_identity_unchanged!(bluebook, aggregate, held_aggregate)
            uncovered = Runtime::EraGuard.uncovered_attributes(aggregate, held_aggregate, rules)
            Runtime::EraGuard.refuse_uncovered!(bluebook, aggregate, uncovered) unless uncovered.empty?
          end
          Runtime::EraGuard.check_vanished_aggregates!(registry, bluebook, held_bluebook)
        end

        # An identity-path change is a RE-KEYING, not a translation:
        # stored ids were fixed at write time under the old key, the
        # audit's id-set conservation and the merge's conflict INTERSECT
        # both assume ids are stable, and no rule in the edge language
        # says "these rows are the same entity under a new key." Until a
        # real re-keying story exists, this refuses in its own words
        # rather than minting a technically-valid era whose conflict
        # detection is meaningless.
        def check_identity_unchanged!(bluebook, aggregate, held_aggregate)
          # The FULL declared path lists, in declaration order — never the
          # single-head shortcut, which is nil for every composite identity
          # and so would let two different composites compare as unchanged.
          return if held_aggregate.identity_paths == aggregate.identity_paths

          held_identity = Runtime::Identity.reading(held_aggregate)
          current_identity = Runtime::Identity.reading(aggregate)
          raise Runtime::WiringError,
                "cannot mint an era for #{bluebook.name}::#{aggregate.name}: its identity path changed " \
                "(#{held_identity} → #{current_identity}), and that is a re-keying, not a translation — " \
                "stored ids were minted under #{held_identity}, and no rule can declare rows the same " \
                "entity under a new key. Keep the identity path, or migrate the data explicitly"
        end

        # Layers 1 and 2 of the audit, over the LIVE compiled chain —
        # before anything is minted, so a refusal leaves no half-born
        # era. (A convert meeting an unmapped value raises inside the
        # preview query itself: same rollback-shaped outcome.)
        def audit!(bluebook, lineage, chain, ordinal, edge)
          violations = []
          bluebook.aggregates.each do |aggregate|
            declared = edge.for_aggregate(aggregate.name)
            after = begin
              lineage.translated_latest(aggregate, ordinal, chain)
            rescue PG::Error => error
              raise Runtime::WiringError, "cannot mint era #{ordinal} of #{bluebook.name}: #{error.message.strip}"
            end
            before = if chain.size > 1
                       lineage.translated_latest(aggregate, ordinal, chain[0..-2])
                     else
                       lineage.ancestor_latest(aggregate, ordinal, chain)
                     end
            verdict = Translation::Audit.check(aggregate: aggregate, declared: declared, before: before, after: after)
            violations.concat(verdict.violations)
          end
          return if violations.empty?

          raise Runtime::WiringError,
                "cannot mint era #{ordinal} of #{bluebook.name}: the audit refused —\n  - #{violations.join("\n  - ")}"
        end

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
