# Keeps every spec off the owner's live event tap (`~/.claude/hecks-dev/events.jsonl`, which the
# pipeline board reads). spec_helper points the tap at the run's temporary file
# (`HECKS_EVENT_TAP`), children included, and the Memory overlay switches it off in this process;
# the runtime's tap refuses the live log outright, so a spec that gets around both fails by name.
# The ledgers are guarded by `LiveLedgerGuard`.
module LiveStateGuard
  # Raised when a spec reaches for live state.
  class Violation < StandardError; end

  # @return [String] the live event tap, as hecks.world names it
  def self.tap_path = File.join(LiveLedgerGuard.dir, "events.jsonl")

  # Prepended to the runtime's event tap, refusing the live log.
  module TapRefusal
    def initialize(path:, **options)
      if LiveLedgerGuard.live?(path)
        raise Violation, "a spec opened the live event tap #{path}; boot with boot_hecks_in_memory, " \
                         "or build a world whose event_log names a temporary path"
      end

      super
    end
  end
end

Hecks::Runtime::EventTap.prepend(LiveStateGuard::TapRefusal)
