module Hecks
  module Runtime
    class Registry
      # Chooses the repository a read goes through: a caught-up projection when one is bound,
      # otherwise the authoritative repository.
      module ReadRepository
        # Resolves and memoizes the repository to read `aggregate` from — a caught-up
        # projection when one is bound and current, otherwise the authoritative repository.
        #
        # @param domain [String, Symbol] name of the domain `aggregate` belongs to
        # @param aggregate [Bluebook::Aggregate] the aggregate to resolve a read
        #   repository for
        # @return [Persistence::AppendOnly] the projection repository when one is bound
        #   and caught up with the authoritative store; the authoritative repository
        #   otherwise
        # @raise [Runtime::WiringError] if the authoritative or projection bind cannot
        #   be resolved
        def read_repository(domain, aggregate)
          key = [domain.to_s, aggregate.hecks_name]
          binding = Ports::Projection.binds_for(self, domain, aggregate).first
          return repository(domain, aggregate) unless binding

          projection = (@projection_repositories[key] ||=
                          Ports::Persistence::RepositoryFactory.build(self, domain, aggregate, binding,
                                                                      recover: true, settings_verb: Ports::Projection::VERB))
          authoritative = repository(domain, aggregate)
          projection_current?(projection, authoritative) ? projection : authoritative
        end

        # Reports whether `projection`'s own journal entries and rows agree with
        # `authoritative`'s, entry-for-entry.
        #
        # @param projection [Persistence::AppendOnly] the projection repository to check
        # @param authoritative [Persistence::AppendOnly] the authoritative repository to
        #   check `projection` against
        # @return [Boolean] true when `projection` holds the same entries and rows as
        #   `authoritative`, in the same order; false on any mismatch, or if comparing
        #   them raises
        def projection_current?(projection, authoritative)
          entries_match?(projection.entries, authoritative.entries) &&
            sorted_rows(projection) == sorted_rows(authoritative)
        rescue StandardError
          false
        end

        private

        def entries_match?(projected_entries, source_entries)
          projected_entries.length == source_entries.length &&
            projected_entries.zip(source_entries).all? do |projected, source|
              projected.operation == source.operation && projected.id == source.id && projected.state == source.state
            end
        end

        def sorted_rows(repository)
          repository.all.map(&:to_h).sort_by { |row| row.fetch(:id).to_s }
        end
      end
    end
  end
end
