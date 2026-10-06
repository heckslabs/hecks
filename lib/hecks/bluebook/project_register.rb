module Hecks
  module Bluebook
    # The callable catalogue for a discovered project. It knows how Bluebook
    # declarations become public FQNs, but never searches or boots folders.
    class ProjectRegister
      Entry = Struct.new(:fqn, :source_directory, :dispatcher, :declared_verb, :domain_version, keyword_init: true) do
        def command? = fqn.command?

        def query?   = fqn.query?
      end

      class DuplicateFqn < StandardError; end
      class MissingRealm < StandardError; end
      class LatestMismatch < StandardError; end

      attr_reader :entries

      def initialize
        @entries = {}
        @tenant_directories = Hash.new { |hash, key| hash[key] = [] }
      end

      # Finds an entry by FQN, such as `"Pizzas.Pizza.Order"`.
      #
      # @raise [KeyError] if no entry is registered under `address`
      def fetch(address) = entries.fetch(address.to_s)

      def include?(address) = entries.key?(address.to_s)

      def commands = entries.values.select(&:command?)

      def queries = entries.values.select(&:query?)

      # Registers every aggregate command/query and read model query of each chapter, under
      # its versioned and (if current) unversioned FQNs.
      #
      # @return [Bluebook::ProjectRegister] self
      # @raise [MissingRealm] if a bluebook's world declares no realm
      # @raise [LatestMismatch] if a world's `latest` disagrees with its bluebook's version
      # @raise [DuplicateFqn] if an FQN this call would register is already registered
      # @raise [Runtime::WiringError] if a second tenant registers the same directory while
      #   an aggregate binds to an adapter that is not `tenant_capable?`
      def register(bluebooks, registry, dispatcher, directory)
        bluebooks.each { |bluebook| register_bluebook(bluebook, registry, dispatcher, directory) }
        self
      end

      private

      # The bluebook being registered and where it is registered from.
      Context = Struct.new(:bluebook, :world, :realm, :directory, :dispatcher)

      def register_bluebook(bluebook, registry, dispatcher, directory)
        refuse_unless_safe_for_second_tenant!(bluebook, registry, directory)
        world = registry.world(bluebook.name)
        realm = world&.realm
        raise MissingRealm, "#{bluebook.name} in #{directory} has no world realm" if realm.to_s.empty?

        refuse_latest_mismatch!(bluebook, world, directory)
        register_declarations(Context.new(bluebook, world, realm, directory, dispatcher))
      end

      def register_declarations(context)
        context.bluebook.aggregates.each { |aggregate| register_aggregate!(aggregate, context) }
        context.bluebook.read_models.each do |model|
          register_pair!(context, :query, model.query_name, model.query_name)
        end
      end

      def refuse_latest_mismatch!(bluebook, world, directory)
        return unless world.latest && bluebook.version && world.latest != bluebook.version

        raise LatestMismatch,
              "#{bluebook.name} in #{directory} declares latest #{world.latest.inspect}, not #{bluebook.version.inspect}"
      end

      def register_aggregate!(aggregate, context)
        aggregate.commands.each do |command|
          register_pair!(context, :command, command.hecks_name, command.hecks_name, aggregate: aggregate.hecks_name)
        end
        aggregate.queries.each do |query|
          register_pair!(context, :query, Naming.snake(query.name), query.name, aggregate: aggregate.hecks_name)
        end
      end

      # Registers the versioned FQN of one command or query, then its unversioned one when the
      # bluebook is the current version.
      def register_pair!(context, kind, name, declared_verb, **scope)
        bluebook = context.bluebook
        register_fqn!(context, kind, name, declared_verb, **scope, version: bluebook.version) if bluebook.version
        register_fqn!(context, kind, name, declared_verb, **scope) if current?(bluebook, context.world)
      end

      def register_fqn!(context, kind, name, declared_verb, **scope)
        fqn = Fqn.public_send(kind, realm: context.realm, domain: context.bluebook.name, **scope, kind => name)
        add(fqn, context.directory, context.dispatcher, declared_verb, context.bluebook.version)
      end

      # A directory's first registration is never refused; only a second one (another tenant
      # sharing the on-disk domain) is, before its routes reach the table. Keyed on
      # `directory` + name, not realm or dispatcher.
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
