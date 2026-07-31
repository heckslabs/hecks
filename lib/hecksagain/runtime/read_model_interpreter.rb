module Hecksagain
  module Runtime
    class ReadModelInterpreter
      def initialize(registry) = @registry = registry

      def call(domain, model, args)
        project(domain, model, args)
      end

      private

      def project(domain, model, args)
        bluebook = @registry.bluebook(domain)
        # BEFORE the adapter early-return below, so the SQLite path inherits it.
        # Without this the two runtimes split on a stale caller: Rust's
        # `query_text` quietly opens a wrapped reference and answers, while Ruby
        # reads it whole and finds nothing.
        refuse_object_reference(model, args)
        reference_id = reference(args.fetch(model.reference_name))
        repository = @registry.read_repository(domain, bluebook.aggregate(model.reference_target))
        if repository.respond_to?(:query_read_model) && repository.adapter.respond_to?(:query_read_model)
          return repository.query_read_model(domain, model, args, bluebook)
        end

        projected = []
        heads = model.aggregate_heads.each_with_object({}) do |head, report|
          rows = if head[:aggregate] == model.reference_target
                   [fetch(bluebook, domain, head[:aggregate], reference_id)]
                 else
                   matching(records(bluebook, domain, head[:aggregate])) do |record|
                     projected.any? do |source|
                       reference_fields(bluebook.aggregate(head[:aggregate]), source[:aggregate]).any? do |field|
                         source[:rows].any? { |parent| reference(record[field]) == parent.id }
                       end
                     end
                   end
                 end
          projected << { aggregate: head[:aggregate], rows: rows }
          report[head[:as]] = head[:many] ? rows : rows.first
        end
        [heads.transform_values { |value| value.is_a?(Array) ? value.map { |record| Value.materialize(row(record)) } : Value.materialize(row(value)) }]
      end

      def fetch(bluebook, domain, aggregate_name, id)
        @registry.read_repository(domain, bluebook.aggregate(aggregate_name)).find(id) || raise(NotFound, "no #{aggregate_name} with reference #{Rendering.describe(id)}")
      end
      def records(bluebook, domain, aggregate_name)
        aggregate = bluebook.aggregate(aggregate_name)
        aggregate ? @registry.read_repository(domain, aggregate).all : []
      end
      # A stored reference holds the target's id inside the REFERENCE
      # ATTRIBUTE's own declared shape, so reading it is reading that shape —
      # a different thing from the identity unwrap that was removed. An
      # IDENTITY is declared as a path and followed (Runtime::Identity) ; a
      # reference has no path of its own, and `Value.scalar` refuses a
      # composite rather than guessing which field was meant.
      #
      # Storing the scalar itself would remove this reading altogether. That
      # is a change to how references are STORED, not to how identities are
      # declared, so it is not made here.
      # An ask names itself where a command would name itself, and says the
      # same thing about the same shape. `Value.refuse_object_reference` is
      # not reused because it speaks of a COMMAND and its attribute ; a read
      # model has a query name and one declared reference.
      def refuse_object_reference(model, args)
        offered = args.fetch(model.reference_name, nil)
        return unless offered.is_a?(Hash) || offered.is_a?(Value)

        raise TypeMismatch,
              "#{model.query_name} refused — a reference is an id, and " \
              "#{model.reference_name} arrived as an object"
      end

      def reference(value) = Value.reference_id(value)
      def reference_fields(aggregate, target)
        aggregate.attributes
                 .select { |attribute| attribute.reference? && attribute.type.target_name == target.to_s }
                 .map(&:name)
      end
      def matching(records) = records.select { |record| yield(record) }.sort_by(&:id)
      def row(record) = record.to_h
    end
  end
end
