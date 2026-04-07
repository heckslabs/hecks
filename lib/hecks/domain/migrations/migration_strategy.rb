module Hecks
  module Migrations
    # Hecks::Migrations::MigrationStrategy
    #
    # Base class for adapter-specific migration generators. Each strategy
    # knows how to turn domain Change objects into migration files for its
    # storage backend. Maintains a class-level registry of strategies so
    # that +run_all+ can dispatch changes to all registered backends.
    #
    # Subclass and implement #generate and #file_path to create a custom strategy:
    #
    #   class RedisMigrationStrategy < Hecks::Migrations::MigrationStrategy
    #     def generate(changes)
    #       # return migration content string, or nil if nothing to do
    #     end
    #
    #     def file_path
    #       "db/redis/#{timestamp}_migration.rb"
    #     end
    #   end
    #
    # Register strategies so MigrationStrategy.run_all picks them up:
    #
    #   Hecks::Migrations::MigrationStrategy.register(:redis, RedisMigrationStrategy)
    #
    class MigrationStrategy

    # Class-level registry mapping strategy names to their classes.
    @registry = {}

    class << self
      # @return [Hash{Symbol => Class}] the registry of named strategies
      attr_reader :registry

      # Register a migration strategy class under a name.
      #
      # @param name [Symbol, String] strategy name (e.g., :sql, :redis)
      # @param strategy_class [Class] a subclass of MigrationStrategy
      # @return [void]
      def register(name, strategy_class)
        @registry[name.to_sym] = strategy_class
      end

      # Look up a strategy class by name.
      #
      # @param name [Symbol, String] strategy name
      # @return [Class, nil] the strategy class, or nil if not registered
      def for(name)
        @registry[name.to_sym]
      end

      # Return all registered strategy classes.
      #
      # @return [Array<Class>] all strategy classes
      def all
        @registry.values
      end

      # Run all registered strategies against a set of changes. Each strategy
      # is instantiated, asked to generate migration content, and if content
      # is produced, writes the migration file to disk.
      #
      # @param changes [Array<DomainDiff::Change>] the detected domain changes
      # @param output_dir [String] base directory for writing migration files (default ".")
      # @return [Array<String>] paths to all generated migration files
      def run_all(changes, output_dir: ".")
        return [] if changes.empty?

        files = []
        @registry.each do |name, strategy_class|
          strategy = strategy_class.new(output_dir: output_dir)
          result = strategy.generate(changes)
          if result
            path = strategy.write(result)
            files << path if path
          end
        end
        files
      end
    end

    # @param output_dir [String] base directory for writing migration files (default ".")
    def initialize(output_dir: ".")
      @output_dir = output_dir
    end

    # Generate migration content from a list of domain changes. Must be
    # overridden by subclasses. Return a string of migration content, or
    # nil if there is nothing to migrate for this strategy.
    #
    # @param changes [Array<DomainDiff::Change>] the detected domain changes
    # @return [String, nil] migration content, or nil to skip
    # @raise [NotImplementedError] if not overridden
    def generate(changes)
      raise NotImplementedError
    end

    # Return the relative file path for the migration output. Must be
    # overridden by subclasses. The path is relative to +output_dir+.
    #
    # @return [String] relative path for the migration file
    # @raise [NotImplementedError] if not overridden
    def file_path
      raise NotImplementedError
    end

    # Write migration content to disk at the path returned by #file_path,
    # relative to the output directory. Creates intermediate directories
    # as needed.
    #
    # @param content [String] the migration content to write
    # @return [String] the full path where the migration was written
    def write(content)
      path = File.join(@output_dir, file_path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      path
    end
    end
  end
end
