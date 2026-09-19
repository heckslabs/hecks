require "hecks/ports/persistence/plugins/era"

module Hecks
  module Fuzzing
    # THE FORK-LOSS CLASS, AS A CHECK — not a fuzz. Every other mode in
    # this file generates a sequence and compares two answers to the SAME
    # question; this one asks a single, unconditional question of a
    # target's own REAL, already-configured `PostgresEra` ledger:
    # does any ancestor era still hold writes nobody has merged forward?
    #
    # THE BUG THIS TARGETS, NAMED EXACTLY. Minting a new era (an attribute
    # or aggregate addition — `StorageShape.project`, lib/hecks/ports/
    # persistence/plugins/era/storage_shape.rb) advances the readable head
    # to a NEW partition; an OLD checkout, or a process that boots slower
    # than the mint, can keep writing into the era it still believes is
    # current. Those writes are not lost — `Lineage#diverged_count`
    # (postgres_era/lineage/tail_merge.rb) can always find them — but
    # nothing EVER asked it automatically. The practice's own ledger found
    # exactly this live, twice: once as an operational gap this session's
    # Step 0 recovered by hand (`bin/merge_tail`, three conflicting
    # records, three eras deep), and once as BUG#24 (a superuser
    # connection walking straight through the era write-fence — fixed by
    # refusing that connection outright, `Lineage#check_fence_applies!`).
    # Both are "a fork happened and nothing said so" — this module is the
    # automatic version of the question `bin/merge_tail`'s own diagnostic
    # line already answers by hand, run as an ordinary sweep Check instead
    # of only when a human remembers to ask.
    #
    # THE TARGET'S REAL DATABASE, READ-ONLY, NEVER A DISPOSABLE ONE — every
    # other Postgres-touching mode here (`persistence_parity`,
    # `adapter_parity_sqlite`) owns a throwaway schema for the exact
    # reason it must never look at what a real deployment actually holds;
    # this check exists FOR what a real deployment actually holds, so it
    # connects the same way `bin/merge_tail` itself does — the target's
    # own `.world` binding — and never writes anything: `eras`/
    # `diverged_count` are both plain `SELECT`s, and `ensure_base!` only
    # ever provisions (`CREATE TABLE IF NOT EXISTS`) when THIS connection
    # is the database's own provisioning owner, the identical idempotent
    # call every ordinary boot already makes. A target with no real,
    # reachable database configured (nothing provisioned locally, say) is
    # reported `checked: false` with the reason — an operational note this
    # mode's own caller surfaces once, never a crash and never silently
    # "clean".
    module EraBoundary
      module_function

      # `{ checked: true, diverged_total:, breakdown: [{ordinal:, diverged:}] }`
      # or `{ checked: false, kind:, reason: "..." }`. A `true` with
      # `diverged_total.positive?` is the finding this module exists to
      # surface: real post-cut writes an ancestor era is still holding.
      #
      # `kind:` SPLITS THE TWO THINGS `checked: false` USED TO MEAN. Both
      # answered the same shape, and `bin/qa_sweep` logged that shape as a
      # HELD Check either way — so a refused connection or a `Lineage`
      # defect read, in the ledger, exactly like an audit that ran and
      # found nothing: counted toward `sweep.made` and the target's clean
      # streak. `:not_applicable` is a target with no lineage to audit at
      # all; `:error` is the audit failing to run, which the caller
      # surfaces as a finding rather than holding.
      def diverged_ancestor_writes(domain_path)
        registry, directory = load_registry(domain_path)
        bluebook = registry.bluebooks.values.first
        return failed("no bluebook in #{directory}") unless bluebook

        first = bluebook.aggregates.first
        return not_applicable("#{bluebook.name} declares no aggregates") unless first

        adapter_name = Hecks::Ports::Persistence::BindingPolicy.resolve(registry, bluebook.name, first).adapter
        unless adapter_name == "PostgresEra"
          return not_applicable("#{bluebook.name} is bound to #{adapter_name}, not PostgresEra")
        end

        settings = registry.world(bluebook.name)&.for_binding(Hecks::Ports::Persistence::VERB, adapter_name) || {}
        db = Hecks::Adapters::PostgresEra.connect_for(bluebook.name, settings)
        begin
          lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, bluebook.name)
          lineage.ensure_base!
          eras = lineage.eras
          # `bin/merge_tail`'s own arithmetic, restated read-only: every
          # ancestor era (every ordinal strictly before the head's own) may
          # still hold post-cut writes the head has never interleaved.
          breakdown = if eras.size > 1
                        (1...eras.last[:ordinal]).map do |ordinal|
                          { ordinal: ordinal, diverged: lineage.diverged_count(ordinal) }
                        end
                      else
                        []
                      end
          { checked: true, era_count: eras.size, breakdown: breakdown, diverged_total: breakdown.sum { |b| b[:diverged] } }
        ensure
          db.close
        end
      rescue StandardError => e
        # COULD NOT AUDIT IS NOT THE SAME AS NOTHING TO AUDIT — a refused
        # connection, a `Lineage` defect, malformed `.world` settings. Every
        # one of these used to answer the benign shape and be HELD.
        failed("#{e.class}: #{e.message}")
      end

      # NOTHING TO AUDIT — this target holds no PostgresEra lineage, so no
      # ancestor era can carry post-cut writes. Not a finding, and not
      # evidence of anything either: the caller logs no Check at all.
      def not_applicable(reason) = { checked: false, kind: :not_applicable, reason: reason }

      # THE AUDIT ITSELF COULD NOT RUN — reported as a finding, never held.
      def failed(reason) = { checked: false, kind: :error, reason: reason }

      # THE SAME LOAD `bin/merge_tail` ITSELF PERFORMS (that script's own
      # top half) — a fresh `Registry`, never the ledger's own (this asks
      # about the SWEPT TARGET's lineage, not QualityControl's own).
      def load_registry(domain_path)
        loading = Hecks::Ports::Loading.bootstrap
        directory = loading.bluebook_directory(domain_path)
        registry = Hecks::Runtime::Registry.new(root: File.dirname(directory))
        Hecks.with_registry(registry) do
          loading.load_library
          loading.load_project(loading.shared_root(nil, directory))
          loading.load_domain(directory)
        end
        [registry, directory]
      end
    end
  end
end
