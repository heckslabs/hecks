module Hecks
  module Bluebook
    # The callable catalogue for a discovered project. It knows how Bluebook
    # declarations become public FQNs, but never searches or boots folders.
    class ProjectRegister
      Entry = Struct.new(:fqn, :source_directory, :dispatcher, :declared_verb, :domain_version, keyword_init: true) do
        # Says whether this entry addresses a command.
        #
        # @return [Boolean] whether this entry's `fqn` addresses a command
        def command? = fqn.command?

        # Says whether this entry addresses a query.
        #
        # @return [Boolean] whether this entry's `fqn` addresses a query
        def query?   = fqn.query?
      end

      class DuplicateFqn < StandardError; end
      class MissingRealm < StandardError; end
      class LatestMismatch < StandardError; end

      attr_reader :entries

      # Starts an empty register, with no domains loaded yet.
      def initialize
        @entries = {}
        @tenant_directories = Hash.new { |hash, key| hash[key] = [] }
      end

      # Finds a registered entry by its fully-qualified verb.
      #
      # @param address [String, #to_s] the FQN to look up, such as `"Pizzas.Pizza.Order"`
      # @return [Bluebook::ProjectRegister::Entry] the entry registered under `address`
      # @raise [KeyError] if no entry is registered under `address`
      def fetch(address) = entries.fetch(address.to_s)

      # Says whether an entry is registered under an address.
      #
      # @param address [String, #to_s] the FQN to check
      # @return [Boolean] whether an entry is registered under `address`
      def include?(address) = entries.key?(address.to_s)

      # Lists every registered command entry.
      #
      # @return [Array<Bluebook::ProjectRegister::Entry>] every registered command entry
      def commands = entries.values.select(&:command?)

      # Lists every registered query entry.
      #
      # @return [Array<Bluebook::ProjectRegister::Entry>] every registered query entry
      def queries  = entries.values.select(&:query?)

      # Registers every aggregate command/query and read model query a booted chapter
      # declares, under its versioned and (if current) unversioned FQNs.
      #
      # @param bluebooks [Array<Bluebook::Chapter>] the booted chapters to register
      # @param registry [Runtime::Registry] the registry `bluebooks` booted into
      # @param dispatcher [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted
      #   dispatcher entries dispatch through
      # @param directory [String] the source directory `bluebooks` was discovered under
      # @return [Bluebook::ProjectRegister] self
      # @raise [Bluebook::ProjectRegister::MissingRealm] if a bluebook's world declares no
      #   realm
      # @raise [Bluebook::ProjectRegister::LatestMismatch] if a world's `latest` disagrees
      #   with its bluebook's own version
      # @raise [Bluebook::ProjectRegister::DuplicateFqn] if an FQN this call would register
      #   is already registered
      # @raise [Runtime::WiringError] if a second tenant registers the same on-disk
      #   directory while any of its aggregates binds to an adapter that is not
      #   `tenant_capable?`
      def register(bluebooks, registry, dispatcher, directory)
        bluebooks.each do |bluebook|
          refuse_unless_safe_for_second_tenant!(bluebook, registry, directory)
          world = registry.world(bluebook.name)
          realm = world&.realm
          raise MissingRealm, "#{bluebook.name} in #{directory} has no world realm" if realm.to_s.empty?
          if world.latest && bluebook.version && world.latest != bluebook.version
            raise LatestMismatch,
                  "#{bluebook.name} in #{directory} declares latest #{world.latest.inspect}, not #{bluebook.version.inspect}"
          end

          bluebook.aggregates.each { |aggregate| register_aggregate!(aggregate, bluebook, world, realm, directory, dispatcher) }
          bluebook.read_models.each { |model| register_read_model!(model, bluebook, world, realm, directory, dispatcher) }
        end
        self
      end

      private

      # Split out of `register` per-aggregate: same versioned-then-current
      # registration shape as `register_read_model!`, just applied to a
      # command/query pair instead of a single report. No state threads
      # back to `register` — each `add` call is independent.
      def register_aggregate!(aggregate, bluebook, world, realm, directory, dispatcher)
        aggregate.commands.each do |command|
          if bluebook.version
            add(Fqn.command(realm: realm, domain: bluebook.name, version: bluebook.version,
                            aggregate: aggregate.hecks_name, command: command.hecks_name),
                directory, dispatcher, command.hecks_name, bluebook.version)
          end
          if current?(bluebook, world)
            add(Fqn.command(realm: realm, domain: bluebook.name, aggregate: aggregate.hecks_name,
                            command: command.hecks_name), directory, dispatcher, command.hecks_name, bluebook.version)
          end
        end
        aggregate.queries.each do |query|
          name = Naming.snake(query.name)
          if bluebook.version
            add(Fqn.query(realm: realm, domain: bluebook.name, version: bluebook.version,
                          aggregate: aggregate.hecks_name, query: name), directory, dispatcher, query.name, bluebook.version)
          end
          if current?(bluebook, world)
            add(Fqn.query(realm: realm, domain: bluebook.name, aggregate: aggregate.hecks_name,
                          query: name), directory, dispatcher, query.name, bluebook.version)
          end
        end
      end

      # Split out of `register` per-read-model: registers the versioned FQN
      # (if this bluebook declares a version) and the current/unversioned
      # FQN (if this bluebook is the world's latest) for one report.
      def register_read_model!(model, bluebook, world, realm, directory, dispatcher)
        if bluebook.version
          add(Fqn.query(realm: realm, domain: bluebook.name, version: bluebook.version,
                        query: model.query_name), directory, dispatcher, model.query_name, bluebook.version)
        end
        if current?(bluebook, world)
          add(Fqn.query(realm: realm, domain: bluebook.name, query: model.query_name),
              directory, dispatcher, model.query_name, bluebook.version)
        end
      end

      # The actual "more than one tenant" moment — Runtime::TenantCheck's
      # own header names this table as the one place real multitenancy
      # happens: the same on-disk directory (one domain, one
      # `persisted_by` binding) registering a second time, under a
      # different realm, into this same shared route table. A directory's
      # first registration is never refused here — nothing shares its
      # data yet, so a plain single-tenant deployment on an ordinary
      # adapter (Postgres, no schema story) still boots exactly as
      # before. Only the second (and any later) registration of that
      # same directory is refused, and refused before this call adds its
      # routes to the table — so a leaking tenant's requests never
      # become reachable through `Router#resolve` in the first place.
      #
      # Keyed on `directory` + `bluebook.name` only, not realm or
      # `dispatcher` — two tenants share the identical on-disk domain,
      # differing only by which realm/environment overlay booted it.
      def refuse_unless_safe_for_second_tenant!(bluebook, registry, directory)
        key = [directory, bluebook.name]
        seen_before = @tenant_directories.key?(key) && @tenant_directories[key].any?
        Runtime::TenantCheck.refuse_unless_tenant_capable!(registry, bluebook.name) if seen_before
        @tenant_directories[key] << registry
      end

      def current?(bluebook, world)
        bluebook.version.nil? || world.latest == bluebook.version
      end

      def add(fqn, directory, dispatcher, declared_verb, domain_version)
        existing = entries[fqn.to_s]
        raise DuplicateFqn, "#{fqn} is declared in both #{existing.source_directory} and #{directory}" if existing

        entries[fqn.to_s] = Entry.new(
          fqn: fqn, source_directory: directory, dispatcher: dispatcher,
          declared_verb: declared_verb, domain_version: domain_version
        )
      end
    end
  end
end
