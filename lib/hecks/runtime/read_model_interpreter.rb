require_relative "../rendering"
require_relative "errors"
require_relative "value"
require_relative "refusal_wording"
require_relative "tenant_scope"
require_relative "../ports/query/in_memory"
require_relative "../query_specification/field_path"

module Hecks
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
        # A ROOTLESS, `group_by`-declared, or `count`/`median`-declared
        # model skips the SQLite native escape hatch entirely (there is
        # no root aggregate to look up a repository FOR when rootless,
        # and `query_read_model` knows nothing about grouping or
        # reducing) — always runs the in-process loop below instead.
        # Correct everywhere ; not SQL-pushed-down for a SQLite-backed
        # aggregate yet, a real, named limit, not a silent one — the
        # same one `group_by` already accepted, extended here rather
        # than narrowed.
        unless rootless || model.group_by.any? || model.count? || model.median_field
          repository = @registry.read_repository(domain, bluebook.aggregate(model.reference_target))
          return repository.query_read_model(domain, model, args, bluebook) if repository.respond_to?(:query_read_model) && repository.adapter.respond_to?(:query_read_model)
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
        (root_heads + order_other_heads(bluebook, root_heads, other_heads)).each do |head|
          rows = if head[:aggregate] == model.reference_target
                   [fetch(bluebook, domain, head[:aggregate], reference_id)]
                 elsif rootless
                   # No root to FK-match against — a rootless model reads
                   # each of its own heads WHOLE, independently. Multiple
                   # heads on one rootless model are NEVER cross-joined
                   # against each other, and there is no DSL to declare
                   # one if you wanted to — `ReadModelBuilder#include_impl`
                   # takes only `type`/`as:` (checked directly, not
                   # assumed), and `group_by` groups this bulk read's own
                   # output, it names no predicate between two heads.
                   # Building a cross-join here would mean CHOOSING a join
                   # semantics (equality on which fields?) nobody has
                   # declared — a real, deliberate scope limit pending a
                   # future `include ..., joins: ...`-shaped grammar
                   # addition (with its own Rust mirror), not a gap this
                   # interpreter can quietly grow into on its own.
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
        reduced_head = aggregation_target(model, bluebook)
        [heads.each_with_object({}) do |(as, value), out|
          out[as] = if grouped_head && as == grouped_head[:as]
                      nest(value.map { |record| Value.materialize_unwrapped(row(record)) }, model.group_by_fields)
                    elsif reduced_head && as == reduced_head[:as] && model.count?
                      value.length
                    elsif reduced_head && as == reduced_head[:as]
                      median(value, model.median_field)
                    elsif value.is_a?(Array)
                      value.map { |record| Value.materialize(row(record)) }
                    else
                      Value.materialize(row(value))
                    end
        end]
      end

      # THE ROOT-FIRST FIX'S OWN FIX — root-first alone only reaches one
      # level: it guarantees the root is in `projected` before any other
      # head is matched, but a CHAIN of non-root heads (a head that
      # references another non-root head, not the root) is still
      # matched against whatever declaration order happened to put in
      # `projected` so far. `include Coupon` before `include Promotion`
      # on a read model rooted at Item, where Coupon references
      # Promotion (which references Item), silently returned an empty
      # `coupons` array — Coupon's match ran while `projected` held only
      # Item, one level short of what it needed.
      #
      # Fixed the same way root-first was: not by asking bluebook authors
      # to declare `include` in dependency order (the same promise
      # `read_model_builder.rb` already makes and this file is the one
      # place obligated to keep), but by topologically sorting the
      # non-root heads on their OWN declared reference fields before
      # this method's runtime matching ever runs — Kahn's algorithm,
      # picking ready heads in DECLARED order at each step so declaring
      # order still governs whenever there is no dependency to break a
      # tie. This generalizes root-first (a chain of length 1) to a
      # chain of any depth, and to a head depending on more than one
      # other head at once (not just a straight chain).
      #
      # A cycle among non-root heads (A references B which references A)
      # has no valid topological order at all — falls back to the
      # remaining heads' declared order rather than looping forever, the
      # same "whichever runs first finds nothing" behaviour this method
      # had for every non-root head before root-first existed.
      def order_other_heads(bluebook, root_heads, other_heads)
        resolved = root_heads.map { |head| head[:aggregate] }
        remaining = other_heads.dup
        ordered = []
        until remaining.empty?
          ready, blocked = remaining.partition do |head|
            depends_on(bluebook, head, other_heads).all? { |target| resolved.include?(target) }
          end
          if ready.empty?
            ordered.concat(remaining)
            break
          end
          ordered.concat(ready)
          resolved.concat(ready.map { |head| head[:aggregate] })
          remaining = blocked
        end
        ordered
      end

      # Which OTHER declared (non-root) heads a head's own aggregate
      # holds a reference field toward — the same relationship this
      # file's runtime matching checks record-by-record, asked here
      # statically, once, to order heads before any record is read.
      #
      # `head[:aggregate]` names whatever `include` was given — and
      # `include` accepts a nested ENTITY (Member, nested under
      # ValueObject ; Handler and Dispatch, nested under ProcessManager
      # — bluebook.bluebook's own `WholeBluebook` read model includes
      # all three) just as readily as a top-level aggregate.
      # `bluebook.aggregate` only ever finds the latter
      # (Behaviour::Chapter#aggregate searches `@aggregates`, which
      # holds no entities), so it returns nil for an entity-headed
      # include — a real case, not a malformed one. `records`, below,
      # already treats that nil as "no rows of its own to fetch" ;
      # a head with no rows of its own has nothing to check for a
      # reference field either, so it depends on nothing here, the
      # same as it always silently read empty before this file's
      # topological sort existed.
      def depends_on(bluebook, head, other_heads)
        aggregate = bluebook.aggregate(head[:aggregate])
        return [] unless aggregate

        other_heads.reject { |other| other[:aggregate] == head[:aggregate] }
                   .select { |other| reference_fields(aggregate, other[:aggregate]).any? }
                   .map { |other| other[:aggregate] }
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
          # THE LIFECYCLE FIELD IS A FIELD, and refusing it here was a drift
          # between two halves of the same language: `where(status: "logged")`
          # has always been legal on the same aggregate, because a lifecycle
          # state is stored on the record like anything else — it is simply
          # declared by `lifecycle :status` rather than by `attribute`.
          #
          # It is also the grouping anybody actually wants. "How are we doing"
          # over a bug ledger IS the count per status, and a report that could
          # group by every field EXCEPT that one could not answer the question
          # reports exist for.
          next if aggregate.lifecycle && aggregate.lifecycle.field.to_sym == field.to_sym

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

      # `count`/`median`'s own declared target — the SAME single
      # many-side head `group_by_target` resolves, for the same reason
      # (`seal_aggregation` already refuses zero or several many-side
      # heads, and refuses count/median declared alongside group_by, so
      # there is exactly one to name whenever this is asked at all).
      # Raises loudly on a `median` field that doesn't exist, or exists
      # but isn't numeric, rather than silently comparing garbage or
      # averaging strings.
      def aggregation_target(model, bluebook)
        return nil unless model.count? || model.median_field

        target = model.aggregate_heads.find { |head| head[:many] }
        return target unless model.median_field

        aggregate = bluebook.aggregate(target[:aggregate])
        attribute = aggregate.attribute(model.median_field)
        unless attribute
          raise ArgumentError,
                "#{model.name}'s median names #{model.median_field.inspect}, but #{target[:aggregate]} " \
                "declares no such attribute (it declares #{aggregate.attributes.map(&:name).join(', ')})"
        end
        unless QuerySpecification::FieldPath.numeric?(attribute, []) { |type| aggregate.value_object(type) }
          raise ArgumentError,
                "#{model.name}'s median names #{model.median_field.inspect} on #{target[:aggregate]}, " \
                "which is not numeric — median needs a numeric field (a bare number, or a " \
                "value object carrying one)"
        end
        target
      end

      # THE STANDARD DEFINITION. An ODD count's median is its one true
      # middle value, sorted ; an EVEN count's median is the AVERAGE of
      # its two middle values — the common convention (as opposed to,
      # say, always taking the lower of the two), and the one this
      # session's own task named explicitly as the deliberate choice.
      # An EMPTY collection has no median: nil, not zero, so a caller
      # cannot mistake "nothing to average" for "the values averaged to
      # zero". Reuses `Ports::Query::InMemory`'s own field reading
      # (`FieldPath.dig` + `comparable`) — the same unwrap `where`/
      # `order_by` already give a value-object-carrying field, so
      # `median :daily_limit` on a `DailyLimit{cents}` field reads the
      # same scalar an `order_by :daily_limit` comparison already would.
      def median(rows, field)
        values = rows.map { |record| Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(row(record), field)) }
                     .compact.sort
        return nil if values.empty?

        middle = values.length / 2
        values.length.odd? ? values[middle] : (values[middle - 1] + values[middle]) / 2.0
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
