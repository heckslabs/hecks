# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaPostgresMigrate
      # The report `sweep.migrate_ledger_from_heki` prints once the copy is done.
      module Reporting
        private

        def report(force, migrated, skipped, conflicts)
          label = force ? "MIGRATED" : "WOULD MIGRATE"
          migrated.each { |id| @out.puts "#{label} #{id}" }
          skipped.each { |id| @out.puts "SKIP #{id}: destination already holds the identical state" }
          conflicts.each { |id| @err.puts refusal(id) }
          @out.puts "" unless [migrated, skipped, conflicts].all?(&:empty?)
          report_summary(force, migrated, skipped, conflicts)
        end

        def refusal(id)
          "REFUSED #{id}: the destination already holds a DIFFERENT state for this id — " \
            "not overwritten, --force or not. Resolve by hand (compare the two states, decide " \
            "which is authoritative) before migrating this id again."
        end

        def report_summary(force, migrated, skipped, conflicts)
          @out.puts "#{force ? "migrated" : "would migrate"} #{migrated.size}, skipped #{skipped.size} " \
                    "(already caught up), refused #{conflicts.size} (conflicting data)"
          @out.puts "re-run with --force to apply" unless force || migrated.empty?
        end
      end
    end
  end
end
