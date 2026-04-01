module Hecks
  # Hecks::Versioning
  #
  # Binds version history tracking to versioned aggregates. Snapshots
  # aggregate state before each save, enabling full history and rollback.
  #
  #   Versioning.bind(klass, repo)
  #   Widget.versions(id)       # => [{ version: 1, state: {...}, at: Time }, ...]
  #   Widget.at_version(id, 1)  # => snapshot hash
  #
  module Versioning
    # Binds version tracking to an aggregate class and its repository.
    #
    # Wraps the repository's +save+ method to snapshot the aggregate's current
    # state (all +hecks_attributes+) before persisting the update. Each snapshot
    # is stored in an in-memory hash keyed by aggregate ID.
    #
    # Also defines two class methods on the aggregate:
    # - +versions(id)+ -- returns the full version history for an aggregate
    # - +at_version(id, version_number)+ -- returns a specific version's state hash
    #
    # @param klass [Class] the aggregate class to add versioning to
    # @param repo [Object] the repository instance whose +save+ method will be wrapped
    # @return [void]
    def self.bind(klass, repo)
      version_store = {}

      klass.instance_variable_set(:@__version_store__, version_store)

      # Wrap save to snapshot before persisting
      original_save = repo.method(:save)
      repo.define_singleton_method(:save) do |aggregate|
        existing = find(aggregate.id)
        if existing
          versions = version_store[aggregate.id] ||= []
          snapshot = {}
          klass.hecks_attributes.each do |attr_def|
            snapshot[attr_def.name] = existing.send(attr_def.name)
          end
          versions << { version: versions.size + 1, state: snapshot, at: Time.now }
        end
        original_save.call(aggregate)
      end

      # Class method: get version history for an aggregate
      klass.define_singleton_method(:versions) do |id|
        version_store[id] || []
      end

      # Class method: get a specific version snapshot
      klass.define_singleton_method(:at_version) do |id, version_number|
        versions = version_store[id] || []
        entry = versions.find { |v| v[:version] == version_number }
        entry&.dig(:state)
      end
    end
  end
end
