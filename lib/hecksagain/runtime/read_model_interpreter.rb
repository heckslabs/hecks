require_relative "../rendering"
require_relative "errors"
require_relative "value"
require_relative "refusal_wording"
require_relative "tenant_scope"
require_relative "../ports/query/in_memory"

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
        # Without this a stale caller passing a wrapped reference gets a
        # path-dependent answer — an adapter could quietly open the wrapped
        # reference while the in-process path reads it whole and finds nothing.
        # Refused up front, identically on every path.
        refuse_object_reference(model, args)
        reference_id = reference(args.fetch(model.reference_name))
        # Computed off the ORIGINAL model, before TenantScope wraps it — the
        # "which head do options apply to" question is about what the
        # bluebook author declared, not about the synthetic tenant clause
        # the wrapper adds underneath.
        eligible = model.filtered_head_name
        model = TenantScope.apply(model, args)
        repository = @registry.read_repository(domain, bluebook.aggregate(model.reference_target))
        if repository.respond_to?(:query_read_model) && repository.adapter.respond_to?(:query_read_model)
          return repository.query_read_model(domain, model, args, bluebook)
        end

        # ROOT FIRST, ALWAYS — regardless of `include` order in the
        # bluebook. `read_model_builder.rb`'s own `include` is
        # documented "Order-independent" (the `:many` flag is resolved
        # at build time, once `@reference_target` is known), but that
        # promise was never kept HERE: this loop used to run heads in
        # their literal declared order and match each "many" head
        # against whatever was ALREADY in `projected` — empty, the
        # very first time through, if a many-side head happened to be
        # declared before the root. A real, live bug (not a guess):
        # `include Promotion` before `include Item` on a read model
        # whose root IS Item silently returned an empty array for
        # Promotion — no error, just a wrong, too-small answer — while
        # the reverse order worked purely by accident. `partition`,
        # not `sort_by`: Ruby's `sort_by` is not guaranteed stable,
        # and correctness here must not depend on it being so by
        # chance on the current MRI build.
        root_heads, other_heads = model.aggregate_heads.partition { |head| head[:aggregate] == model.reference_target }
        projected = []
        rows_by_as = {}
        (root_heads + other_heads).each do |head|
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
          rows = Ports::Query::InMemory.execute(rows, model, args) if head[:as] == eligible
          projected << { aggregate: head[:aggregate], rows: rows }
          rows_by_as[head[:as]] = head[:many] ? rows : rows.first
        end
        # Declared order preserved in the OUTPUT — only the
        # computation above needed reordering, not what a caller sees
        # back.
        heads = model.aggregate_heads.each_with_object({}) { |head, report| report[head[:as]] = rows_by_as[head[:as]] }
        [heads.transform_values { |value| value.is_a?(Array) ? value.map { |record| Value.materialize(row(record)) } : Value.materialize(row(value)) }]
      end

      def fetch(bluebook, domain, aggregate_name, id)
        @registry.read_repository(domain, bluebook.aggregate(aggregate_name)).find(id) ||
          raise(NotFound, RefusalWording.render("NotFound", "read_model_reference_missing",
                                                 aggregate: aggregate_name, offered: Rendering.describe(id)))
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
              RefusalWording.render("TypeMismatch", "read_model_object_reference",
                                    query: model.query_name, field: model.reference_name)
      end

      # A reference is the id, in the argument and in the stored row alike.
      def reference(value) = value.to_s
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
