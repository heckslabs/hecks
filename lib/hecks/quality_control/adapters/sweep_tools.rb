# frozen_string_literal: true

require_relative "qa_tool"

module Hecks
  module Adapters
    # The `SweepTools` port's adapter: answers `Sweep`'s queries by running the QA commands that
    # work a whole pass: a tick, a sweep, the Heki migration, the ledger's role and a concurrency
    # racer. A run that finds something ends with status 2, which is an answer; anything else the
    # command calls an error is refused with its report.
    class SweepTools < QaTool
      # @return [Hash] `text:` one tick's report
      def tick
        run_command("qa_tick", answers: [0, 2])
      end

      # @param target [Hash, String, nil] the target to sweep; the rotation's pick when absent
      # @param arguments [Hash, String, nil] the sweep's own flags, such as `--all --seeds 5`
      # @return [Hash] `text:` the sweep's report
      def run(target: nil, arguments: nil)
        run_command("qa_sweep", *plain(target), *words(arguments), answers: [0, 2])
      end

      # @param domain [Hash, String] the domain directory whose bindings are the destination
      # @param data [Hash, String] the Heki data directory read from
      # @param arguments [Hash, String, nil] aggregate names, and `--force` to apply
      # @return [Hash] `text:` what was, or would be, migrated
      def migrate_ledger_from_heki(domain:, data:, arguments: nil)
        run_command("qa_postgres_migrate", plain(domain), plain(data), *words(arguments))
      end

      # @param database [Hash, String] the database the role is made to own
      # @param role [Hash, String, nil] the role's name; `hecks_qa` when absent
      # @return [Hash] `text:` what was done, and what already held
      def create_ledger_role(database:, role: nil)
        run_command("qa_postgres_role", plain(database), *(role ? ["--role", plain(role)] : []))
      end

      # @param domain [Hash, String] the domain directory
      # @param database [Hash, String] the scratch database
      # @param schema [Hash, String] the schema this racer dispatches into
      # @param verb [Hash, String] the command to dispatch
      # @param step_arguments [Hash, String] the command's arguments, as JSON
      # @return [Hash] `text:` `succeeded`, `refused` or `crashed:<class>: <message>`
      def race(domain:, database:, schema:, verb:, step_arguments:)
        run_command("qa_concurrency_racer", plain(domain), plain(database), plain(schema), plain(verb),
                    plain(step_arguments))
      end
    end
  end
end
