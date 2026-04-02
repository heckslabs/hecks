# Hecks::EventSourcing::VersionCheckStep
#
# A lifecycle step that enforces optimistic concurrency on commands.
# When a command carries an `expected_version` attribute, this step
# compares it against the stored aggregate's current version and raises
# ConcurrencyError on mismatch.
#
# == Usage
#
#   # Insert into the command lifecycle pipeline before CallStep:
#   pipeline = [GuardStep, VersionCheckStep, CallStep, ...]
#
module Hecks
  module EventSourcing
    VersionCheckStep = ->(cmd) {
      if cmd.respond_to?(:expected_version) && cmd.expected_version
        repo = cmd.class.repository
        existing = repo.find(cmd.id) if cmd.respond_to?(:id) && cmd.id
        if existing
          actual = Concurrency.version_of(existing)
          Concurrency.check!(expected: cmd.expected_version.to_i, actual: actual)
        end
      end
      cmd
    }
  end
end
