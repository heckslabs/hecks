# Keeps every spec off the owner's live ledger (`~/.claude/hecks-dev`: tickets.db, agent_run.db).
#
# A checkout's gitignored `hecks.local.world` binds Tickets and AgentRun to absolute paths there,
# so a spec that boots a domain through the local overlay writes to them. Booting through
# `boot_hecks_in_memory` shuts that overlay out; this guard is the backstop for any other boot:
# the SQLite store refuses to open a file under the live directory while a spec runs, and the
# spec fails by name instead of filling the ledger. `HECKS_LIVE_LEDGER_DIR` moves the directory
# (a spec's own temp tree is never under it).
module LiveLedgerGuard
  # The live ledger's directory, symlinks resolved.
  def self.dir
    File.expand_path(ENV.fetch("HECKS_LIVE_LEDGER_DIR", "~/.claude/hecks-dev"))
  end

  # @param path [String] a database file a store is about to open
  # @return [Boolean] whether it lies under the live ledger directory
  def self.live?(path)
    File.expand_path(path.to_s).start_with?("#{dir}/")
  end

  # Raised when a spec reaches for the live ledger.
  class Violation < StandardError; end

  # Prepended to the SQLite store, refusing the live ledger's files.
  module Refusal
    private

    def open_database
      raise Violation, "a spec opened the live ledger #{@path}; boot with boot_hecks_in_memory" if LiveLedgerGuard.live?(@path)

      super
    end
  end
end

Hecks::Adapters::Sqlite.prepend(LiveLedgerGuard::Refusal)
