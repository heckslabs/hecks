module Hecks
  module Rails
    # The one booted domain a Rails app runs on: its dispatcher, and the lookups models, routes and
    # controllers make against its chapters. It hands out core handles and never installs a module.
    class BootedDomain
      # A chapter and one of its aggregates, as a model names them: `"Banking.Account"`.
      Address = Struct.new(:chapter, :aggregate) do
        # @return [String] the aggregate's fully qualified name, `"Banking::Account"`
        def fqn = "#{chapter}::#{aggregate.hecks_name}"
      end

      # @return [Object] the dispatcher the boot answered, adapter-defined
      attr_reader :dispatcher

      # @param dispatcher [Object] the dispatcher `Hecks.boot` answered
      def initialize(dispatcher)
        @dispatcher = dispatcher
      end

      # Answers the registry the domain booted into.
      #
      # @return [Object] the booted registry, adapter-defined
      def registry = @dispatcher.registry

      # Finds a chapter by its name in any case, so a route file may say `"banking"`.
      #
      # @param name [String, Symbol] the chapter's name, `"Banking"` or `"banking"`
      # @return [Bluebook::Chapter] the chapter
      # @raise [ArgumentError] if the domain holds no chapter of that name
      def chapter(name)
        found = registry.bluebooks.values.find { |chapter| chapter.name.casecmp?(name.to_s) }
        found or raise ArgumentError, "the booted domain holds no chapter named #{name.inspect}"
      end

      # Resolves a model's `"Chapter.Aggregate"` name.
      #
      # @param qualified [String] the chapter and aggregate, dotted: `"Banking.Account"`
      # @return [Rails::BootedDomain::Address] the chapter's name and the aggregate's IR
      # @raise [ArgumentError] if the chapter or the aggregate is not in the domain
      def address(qualified)
        chapter_name, aggregate_name = qualified.to_s.split(".", 2)
        held = chapter(chapter_name)
        aggregate = held.aggregate(aggregate_name.to_s) or
          raise ArgumentError, "#{held.name} declares no aggregate named #{aggregate_name.inspect}"
        Address.new(held.name, aggregate)
      end

      # Finds the aggregate that declares a command.
      #
      # @param command [Bluebook::Command] a command of one of the domain's aggregates
      # @return [Rails::BootedDomain::Address, nil] its owner; nil when no aggregate declares it
      def owner_of(command)
        registry.bluebooks.each_value do |chapter|
          chapter.aggregates.each do |aggregate|
            return Address.new(chapter.name, aggregate) if aggregate.commands.include?(command)
          end
        end
        nil
      end

      # Finds one record.
      #
      # @param address [Rails::BootedDomain::Address] the record's aggregate
      # @param id [String, Hash] the record's identity
      # @return [Adapters::Driving::Handle, nil] the record; nil when none has that identity
      def find(address, id)
        found = repository(address).find(id)
        found && handle(address, found)
      end

      # Lists the aggregate's records.
      #
      # @param address [Rails::BootedDomain::Address] the aggregate
      # @return [Array<Adapters::Driving::Handle>] every stored record, in the store's order
      def all(address) = repository(address).all.map { |found| handle(address, found) }

      # Counts the aggregate's records.
      #
      # @param address [Rails::BootedDomain::Address] the aggregate
      # @return [Integer] how many records are stored
      def count(address) = repository(address).count

      # Runs a creating command.
      #
      # @param address [Rails::BootedDomain::Address] the aggregate the command creates one of
      # @param command [Bluebook::Command] the creating command
      # @param args [Hash{Symbol => Object}] the command's facts
      # @return [Adapters::Driving::Handle] the created record
      # @raise [Hecks::Refused] when the domain refuses the command
      def create(address, command, args)
        created = @dispatcher.dispatch("#{address.fqn}.#{command.hecks_name}", with: args).instance
        handle(address, created)
      end

      # Runs one query.
      #
      # @param address [Rails::BootedDomain::Address] the aggregate that declares the query
      # @param query [Bluebook::Query] the query
      # @param args [Hash{Symbol => Object}] the query's arguments
      # @return [Array<Hash>] the rows the query answers
      # @raise [Hecks::Refused] when the domain refuses the query
      def query(address, query, args) = @dispatcher.query("#{address.fqn}.#{query.hecks_name}", **args)

      private

      def repository(address) = registry.repository(address.chapter, address.aggregate)

      def handle(address, instance)
        Adapters::Driving::Handle.new(dispatcher: @dispatcher, domain: address.chapter,
                                      aggregate: address.aggregate, instance: instance)
      end
    end
  end
end
