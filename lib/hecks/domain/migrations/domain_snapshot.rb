module Hecks
  module Migrations
    # Hecks::Migrations::DomainSnapshot
    #
    # Saves and loads domain DSL snapshots for migration diffing. When
    # migrations are generated, the current domain is serialized to a
    # snapshot file using DslSerializer. On the next run, the snapshot is
    # loaded as the "old" domain to diff against the current one.
    #
    # The snapshot file is valid Ruby DSL code that reconstructs the domain
    # when evaluated. The default location is +.hecks_domain_snapshot.rb+
    # in the project root.
    #
    #   DomainSnapshot.save(domain, path: ".hecks_domain_snapshot.rb")
    #   old_domain = DomainSnapshot.load(path: ".hecks_domain_snapshot.rb")
    #
    class DomainSnapshot

    # Default file path for the snapshot file, relative to the project root.
    DEFAULT_PATH = ".hecks_domain_snapshot.rb"

    # Serialize a domain to a snapshot file using DslSerializer. The file
    # contains valid Ruby DSL code that can be evaluated to reconstruct
    # the domain.
    #
    # @param domain [Hecks::DomainModel::Domain] the domain to snapshot
    # @param path [String] file path for the snapshot (default DEFAULT_PATH)
    # @return [String] the path where the snapshot was written
    def self.save(domain, path: DEFAULT_PATH)
      content = DslSerializer.new(domain).serialize
      File.write(path, content)

      # Validate round-trip fidelity if possible
      restored = self.load(path: path)
      if restored
        result = HecksTemplating::MigrationContract.diff(domain, restored)
        unless result[:valid]
          warn "MigrationContract: snapshot round-trip issues:\n  #{result[:issues].join("\n  ")}"
        end
      end

      path
    end

    # Load a domain from a snapshot file. Evaluates the Ruby DSL code in
    # the snapshot and returns the resulting domain via +Hecks.last_domain+.
    # Returns nil if the snapshot file does not exist.
    #
    # @param path [String] file path for the snapshot (default DEFAULT_PATH)
    # @return [Hecks::DomainModel::Domain, nil] the loaded domain, or nil
    #   if no snapshot exists
    def self.load(path: DEFAULT_PATH)
      return nil unless File.exist?(path)

      Kernel.load(path)
      Hecks.last_domain
    end

    # Check whether a snapshot file exists at the given path.
    #
    # @param path [String] file path to check (default DEFAULT_PATH)
    # @return [Boolean] true if the snapshot file exists
    def self.exists?(path: DEFAULT_PATH)
      File.exist?(path)
    end
    end
  end
end
