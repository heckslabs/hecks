require "json"
require_relative "../../hecks"
require_relative "persistence_notice"

module Hecks
  module CLI
    # The command behind `hecks stores`: every aggregate's current
    # records as JSON (the head, not the journal — see `hecks history` for that).
    module Stores
      module_function

      # Boots the domain `argv` names and prints its stores as one JSON document.
      #
      # @param argv [Array<String>] the domain directory, first
      # @param program [String] the name the error message calls this command by
      # @return [void]
      # @raise [SystemExit] when `argv` is empty or the domain directory does not exist
      def call(argv, program:)
        domain = argv.first or abort "usage: #{program} <domain>"
        unless Dir.exist?(domain)
          warn "#{program}: no such domain #{domain.inspect}"
          exit 1
        end

        registry = Hecks.boot(domain).registry
        PersistenceNotice.announce(registry, program: program)
        puts JSON.generate(stores_of(registry))
      end

      # @param registry [Runtime::Registry] a booted domain's registry
      # @param only [String, nil] a storage name; the other aggregates' repositories are not read
      # @return [Hash{String => Hash}] each aggregate's dump, keyed by its storage name
      def stores_of(registry, only: nil)
        registry.bluebooks.each_with_object({}) do |(name, bluebook), all|
          bluebook.aggregates.each do |aggregate|
            next if only && aggregate.storage_name != only

            all[aggregate.storage_name] = data_for(registry.repository(name, aggregate))
          end
        end
      end

      # Reads what was asked for: reads only the named aggregate's repository when one is named.
      #
      # @param registry [Runtime::Registry] a booted domain's registry
      # @param aggregate [String, nil] a storage name; nil reads every aggregate
      # @param record [String, nil] a record id within `aggregate`
      # @return [Hash] see `narrow`
      # @raise [Runtime::NotFound] see `narrow`
      def read(registry, aggregate, record)
        document = stores_of(registry, only: aggregate)
        narrow(document, aggregate, record, names: stored_names(registry))
      end

      # Narrows the whole document to what was asked for: all of it, one aggregate's dump, or
      # one record of an aggregate as its plain fields.
      #
      # @param document [Hash{String => Hash}] `stores_of`'s answer
      # @param aggregate [String, nil] a storage name from the document; nil keeps everything
      # @param record [String, nil] a record id within `aggregate`; nil keeps its whole dump
      # @param names [Array<String>] the storage names to list when `aggregate` is not stored
      # @return [Hash] the whole document, `{ aggregate => dump }`, or the one record's fields
      # @raise [Runtime::NotFound] when the aggregate is not stored, the record is not in it, or a
      #   record is named without an aggregate
      def narrow(document, aggregate, record, names: document.keys)
        raise Runtime::NotFound, "name the aggregate the record is in" if record && !aggregate
        return document unless aggregate

        dump = document.fetch(aggregate) do
          raise Runtime::NotFound, "no aggregate stored as #{aggregate.inspect}; stored: #{names.join(", ")}"
        end
        record ? one_record(dump, aggregate, record) : { aggregate => dump }
      end

      # The storage names a booted domain keeps records under, read without reading any record.
      #
      # @param registry [Runtime::Registry] a booted domain's registry
      # @return [Array<String>] one storage name per aggregate
      def stored_names(registry)
        registry.bluebooks.values.flat_map { |bluebook| bluebook.aggregates.map(&:storage_name) }
      end

      # @api private
      def one_record(dump, aggregate, record)
        dump.fetch("authoritative").find { |row| row["id"] == record } or
          raise Runtime::NotFound, "no #{aggregate} record with id #{record.inspect}"
      end

      # Reads one aggregate's current records as plain JSON-ready hashes, ordered by id.
      #
      # @param repository [Ports::Persistence::AppendOnly] the aggregate's repository
      # @return [Array<Hash{String => Object}>] one hash per stored `Runtime::Instance`,
      #   sorted by id; `[]` when the aggregate has no records
      def records(repository)
        repository.all.sort_by(&:id).map { |instance| JSON.parse(JSON.generate(instance.to_h)) }
      end

      # Shapes one aggregate's dump for the top-level stores document.
      #
      # @param repository [Ports::Persistence::AppendOnly] the aggregate's repository
      # @return [Hash{String => Object}] `"authoritative"` mapped to `records(repository)`
      def data_for(repository)
        { "authoritative" => records(repository) }
      end
    end
  end
end
