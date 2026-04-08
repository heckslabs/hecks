# Hecks::DomainVersioning::BreakingBumper
#
# Auto-bumps the domain CalVer version when breaking changes are detected.
# Compares the current domain against the latest tagged snapshot using
# DomainDiff and BreakingClassifier. If any breaking changes exist, calls
# versioner.next to bump the version; otherwise returns the current version.
#
#   result = BreakingBumper.call(old_domain, new_domain, versioner)
#   result[:bumped]           # => true
#   result[:version]          # => "2026.04.01.2"
#   result[:breaking_changes] # => [{ change: ..., label: "...", breaking: true }]
#
module Hecks
  module DomainVersioning
    # Hecks::DomainVersioning::BreakingBumper
    #
    # Auto-bumps the domain CalVer version when breaking changes are detected between two domain snapshots.
    #
    module BreakingBumper
      # Evaluate whether a version bump is needed based on breaking changes.
      #
      # @param old_domain [Hecks::BluebookModel::Domain, nil] previous snapshot (nil = first build)
      # @param new_domain [Hecks::BluebookModel::Domain] current domain
      # @param versioner [Hecks::Versioner] CalVer versioner instance
      # @return [Hash] with :version, :breaking_changes, :bumped keys
      def self.call(old_domain, new_domain, versioner)
        if old_domain.nil?
          version = versioner.next
          return { version: version, breaking_changes: [], bumped: false }
        end

        changes = Hecks::Migrations::DomainDiff.call(old_domain, new_domain)
        classified = BreakingClassifier.classify(changes)
        breaking = classified.select { |c| c[:breaking] }

        if breaking.any?
          version = versioner.next
          { version: version, breaking_changes: breaking, bumped: true }
        else
          version = versioner.current || versioner.next
          { version: version, breaking_changes: [], bumped: false }
        end
      end
    end
  end
end
