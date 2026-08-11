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
        rootless = model.reference_target.nil?
        # BEFORE the adapter early-return below, so the SQLite path inherits it.
        # Without this a stale caller passing a wrapped reference gets a
        # path-dependent answer — an adapter could quietly open the wrapped
        # reference while the in-process path reads it whole and finds nothing.
        # Refused up front, identically on every path. Nothing to refuse for
        # a rootless model — there's no reference argument to have offered
        # wrong at all.
        refuse_object_reference(model, args) unless rootless
        reference_id = reference(args.fetch(model.reference_name)) unless rootless
        # Computed off the ORIGINAL model, before TenantScope wraps it — the
        # "which head do options apply to" question is about what the
        # bluebook author declared, not about the synthetic tenant clause
        # the wrapper adds underneath.
        eligible = model.filtered_head_name
        model = TenantScope.apply(model, args)
        # A ROOTLESS or `group_by`-declared model skips the SQLite native
        # escape hatch entirely (there is no root aggregate to look up a
        # repository FOR when rootless, and `query_read_model` knows
        # nothing about grouping) — always runs the in-process loop below
        # instead. Correct everywhere ; not SQL-pushed-down for a SQLite-
        # backed aggregate yet, a real, named limit, not a silent one.
        unless rootless || model.group_by.any?
          repository = @registry.read_repository(domain, bluebook.aggregate(model.reference_target))
          if repository.respond_to?(:query_read_model) && repository.adapter.respond_to?(:query_read_model)
            return repository.query_read_model(domain, model, args, bluebook)
          end
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
                 elsif rootless
                   # No root to FK-match against — a rootless model reads
                   # each of its own heads WHOLE, independently. (Multiple
                   # heads on one rootless model aren't cross-joined
                   # against each other either — each is its own bulk
                   # read. A real, deliberate scope limit for now.)
                   records(bluebook, domain, head[:aggregate])
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
        grouped_head = group_by_target(model, bluebook)
        [heads.each_with_object({}) do |(as, value), out|
          out[as] = if grouped_head && as == grouped_head[:as]
                      nest(value.map { |record| Value.materialize_unwrapped(row(record)) }, model.group_by_fields)
                    elsif value.is_a?(Array)
                      value.map { |record| Value.materialize(row(record)) }
                    else
                      Value.materialize(row(value))
                    end
        end]
      end

      # `group_by`'s own declared fields, checked against the ONE
      # many-side head they apply to (`seal_group_by` already refuses
      # zero or several) — resolved here, once, rather than re-derived
      # per row. Raises loudly on a typo'd field name rather than
      # silently grouping every row into one bucket keyed `nil`.
      def group_by_target(model, bluebook)
        return nil unless model.group_by.any?

        target = model.aggregate_heads.find { |head| head[:many] }
        aggregate = bluebook.aggregate(target[:aggregate])
        model.group_by_fields.each do |field|
          next if aggregate.attribute(field)

          raise ArgumentError,
                "#{model.name}'s group_by names #{field.inspect}, but #{target[:aggregate]} " \
                "declares no such attribute (it declares #{aggregate.attributes.map(&:name).join(', ')})"
        end
        target
      end

      # One level of nesting per field, in `group_by`'s own declared
      # order — the leaf is the row with every grouped field removed
      # (already spent, as the keys that reached it). ASSUMES the full
      # `group_by` path uniquely identifies one row (true for grouping by
      # an aggregate's own full identity, ConsoleSettings' own real use)
      # — `leaves.first` silently keeps only the first row when several
      # share the same full key path. A real, deliberate scope limit:
      # true multi-row-per-leaf grouping would change the leaf shape
      # from "one row" to "an array of rows", which no caller needs yet.
      def nest(rows, fields)
        field, *rest = fields
        rows.group_by { |row| row[field] }.transform_values do |group|
          # Strip ONLY the field just grouped by, not the whole remaining
          # list — `rest`'s own fields have to survive into the recursive
          # call below, or the NEXT level groups by a key that's already
          # gone (found by trying it: a two-field group_by's own second
          # level came back keyed `nil` for every group, every time).
          stripped = group.map { |row| row.reject { |key, _| key == field } }
          rest.empty? ? stripped.first : nest(stripped, rest)
        end
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
