require_relative "../../../indifferent_key"

module Hecks
  module Adapters
    class PostgresRevision
      # Connects a boot to its database without provisioning it: the connection selects the declared
      # schema and creates nothing. Only the mint path opens with `PostgresRevision.connect_for`,
      # which
      # creates the schema.
      module ReadConnector
        # @param name [String] the domain or aggregate name, used only in refusal messages
        # @param settings [Hash{Symbol, String => Object}] the persistence settings of the boot
        # @return [PG::Connection] an open connection that writes no schema
        def self.connect_for(name, settings) = PostgresRevision.connect_for(name, settings, provision: false)
      end

      # The steps `PostgresRevision#initialize` runs after joining the shared connection: naming the
      # journal, resolving the era it reads, and reading the field caches that era holds. A boot
      # writes nothing; the mint path provisions everything.
      module Boot
        private

        # Journal name: the owning bluebook's declared name, matching the key rust/host derives its
        # advisory lock from (ADR 0036). A bare aggregate with no owner falls back to its own name.
        def journal_domain(aggregate, settings)
          owner = aggregate.hecks_owner
          self.class.setting(
            settings, :domain, default: owner&.name || aggregate.storage_name
          ).to_s
        end

        # Resolves the era this boot reads. A database that holds no era has never been minted, so
        # the boot refuses by name rather than reading an absent lineage.
        #
        # The era is read from the held eras, never written: the factory passes `era:` once the
        # boot gate resolved it, and nil can never be a real override.
        def resolve_era!(settings)
          @era = IndifferentKey.read(settings, :era)
          held = @lineage.eras
          refuse_unminted! if held.empty?
          @era ||= held.last[:ordinal]
          # Non-nil only for a held-but-superseded boot. `append` and `atomic_put` refuse on it
          # because a superuser walks through the RLS fence.
          @superseded_by = IndifferentKey.read(settings, :superseded_by)
          # True only for a boot whose shape no held era matches and that carries no mint request.
          # It reads the latest era and refuses writes until a mint runs.
          @unminted = IndifferentKey.read(settings, :unminted) == true
        end

        # @raise [Runtime::WiringError] always: the database holds no era for a boot to read
        def refuse_unminted!
          raise Runtime::WiringError,
                "cannot boot #{@domain}: no era held; the database is unminted, so run the mint entry " \
                "point (`hecks era.hold_first! <domain directory> --confirm`) to provision and hold the first era"
        end
      end
    end
  end
end
