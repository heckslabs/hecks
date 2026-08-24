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
      end

      def fetch(address) = entries.fetch(address.to_s)
      def include?(address) = entries.key?(address.to_s)
      def commands = entries.values.select(&:command?)
      def queries  = entries.values.select(&:query?)

      def register(bluebooks, registry, dispatcher, directory)
        bluebooks.each do |bluebook|
          world = registry.world(bluebook.name)
          realm = world&.realm
          raise MissingRealm, "#{bluebook.name} in #{directory} has no world realm" if realm.to_s.empty?
          if world.latest && bluebook.version && world.latest != bluebook.version
            raise LatestMismatch,
                  "#{bluebook.name} in #{directory} declares latest #{world.latest.inspect}, not #{bluebook.version.inspect}"
          end

          bluebook.aggregates.each do |aggregate|
            aggregate.commands.each do |command|
              add(Fqn.command(realm: realm, domain: bluebook.name, version: bluebook.version,
                              aggregate: aggregate.hecks_name, command: command.hecks_name), directory, dispatcher, command.hecks_name, bluebook.version) if bluebook.version
              add(Fqn.command(realm: realm, domain: bluebook.name, aggregate: aggregate.hecks_name,
                              command: command.hecks_name), directory, dispatcher, command.hecks_name, bluebook.version) if current?(
                                bluebook, world
                              )
            end
            aggregate.queries.each do |query|
              name = Naming.snake(query.name)
              add(Fqn.query(realm: realm, domain: bluebook.name, version: bluebook.version,
                            aggregate: aggregate.hecks_name, query: name), directory, dispatcher, query.name, bluebook.version) if bluebook.version
              add(Fqn.query(realm: realm, domain: bluebook.name, aggregate: aggregate.hecks_name,
                            query: name), directory, dispatcher, query.name, bluebook.version) if current?(bluebook, world)
            end
          end
          bluebook.read_models.each do |model|
            add(Fqn.query(realm: realm, domain: bluebook.name, version: bluebook.version,
                          query: model.query_name), directory, dispatcher, model.query_name, bluebook.version) if bluebook.version
            add(Fqn.query(realm: realm, domain: bluebook.name, query: model.query_name),
                directory, dispatcher, model.query_name, bluebook.version) if current?(bluebook, world)
          end
        end
        self
      end

      private

      def current?(bluebook, world)
        bluebook.version.nil? || world.latest == bluebook.version
      end

      def add(fqn, directory, dispatcher, declared_verb, domain_version)
        existing = entries[fqn.to_s]
        if existing
          raise DuplicateFqn, "#{fqn} is declared in both #{existing.source_directory} and #{directory}"
        end

        entries[fqn.to_s] = Entry.new(
          fqn: fqn, source_directory: directory, dispatcher: dispatcher,
          declared_verb: declared_verb, domain_version: domain_version
        )
      end
    end
  end
end
