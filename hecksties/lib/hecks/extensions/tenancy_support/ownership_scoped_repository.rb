module HecksTenancy
  # HecksTenancy::OwnershipScopedRepository
  #
  # Repository proxy that enforces row-level ownership. Wraps an inner
  # repository instance and restricts find/all/delete to records whose
  # ownership field matches the current identity (from +identity_source+).
  #
  # Used by the Hecks runtime when a gate declares +owned_by :field+.
  # Also used for +:row+ tenancy strategy (identity_source reads +Hecks.tenant+).
  #
  #   repo = OwnershipScopedRepository.new(
  #     inner_repo,
  #     ownership_field: :owner_id,
  #     identity_source: -> { Hecks.current_user }
  #   )
  #   Hecks.current_user = "alice"
  #   repo.all           # => only alice's records
  #   repo.find(other_id) # => raises Hecks::GateAccessDenied
  #
  class OwnershipScopedRepository
    # @param inner_repo [Object] the underlying repository to wrap
    # @param ownership_field [Symbol] attribute name identifying the owner
    # @param identity_source [Proc] callable returning the current identity
    def initialize(inner_repo, ownership_field:, identity_source: -> { Hecks.current_user })
      @inner = inner_repo
      @ownership_field = ownership_field.to_sym
      @identity_source = identity_source
    end

    # Find a record by ID and verify ownership.
    #
    # @param id [String] aggregate ID to look up
    # @return [Object] the found aggregate
    # @raise [Hecks::GateAccessDenied] if the record is owned by someone else
    def find(id)
      record = @inner.find(id)
      return nil if record.nil?
      verify_ownership!(record)
      record
    end

    # Return all records owned by the current identity.
    #
    # @return [Array<Object>] records whose ownership_field matches current identity
    def all
      identity = current_identity
      @inner.all.select { |r| r.public_send(@ownership_field) == identity }
    end

    # Persist a record (delegates directly, ownership stamping is the caller's job).
    #
    # @param aggregate [Object] the aggregate to save
    # @return [Object] saved aggregate
    def save(aggregate)
      @inner.save(aggregate)
    end

    # Delete a record by ID after verifying ownership.
    #
    # @param id [String] aggregate ID to delete
    # @raise [Hecks::GateAccessDenied] if the record is owned by someone else
    # @return [void]
    def delete(id)
      record = @inner.find(id)
      verify_ownership!(record) if record
      @inner.delete(id)
    end

    # Return count of records owned by the current identity.
    #
    # @return [Integer]
    def count
      all.size
    end

    # Remove all records owned by the current identity from the inner store.
    #
    # @return [void]
    def clear
      all.each { |r| @inner.delete(r.id) }
    end

    # Query records, filtering results to owned records.
    #
    # @param kwargs [Hash] passed through to the inner repository's +query+ method
    # @return [Array<Object>] owned matching records
    def query(**kwargs)
      identity = current_identity
      @inner.query(**kwargs).select { |r| r.public_send(@ownership_field) == identity }
    end

    private

    def current_identity
      @identity_source.call
    end

    def verify_ownership!(record)
      identity = current_identity
      owner = record.public_send(@ownership_field)
      return if owner == identity
      raise Hecks::GateAccessDenied,
            "Access denied: record owned by #{owner.inspect}, current identity is #{identity.inspect}"
    end
  end
end
