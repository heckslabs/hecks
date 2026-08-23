require_relative "null_policy"
require_relative "../../runtime/value"

module Hecksagain
  module QuerySpecification
    module Common
      # THE ONE COMPARATOR TABLE. There were two, near-identical copies of
      # this — `Ports::Query::InMemory` (the path a Memory- or Heki-backed
      # aggregate query actually runs) and `Runtime::QueryInterpreter`
      # (entity/sub-list queries, and any adapter implementing no `:query`)
      # — plus a third partial reading of `comparable` inside
      # `SqlQueryBuilder#query_value`.
      #
      # Two copies of one rule is not a style complaint here; it has cost
      # real bugs twice already, both recorded in the comments those files
      # carried. `none_in_state` was added to one copy only, so an ordinary
      # Memory query's `none_in_state` clause fell to the `else` branch and
      # silently excluded every row. And `comparable` DIVERGED without
      # anyone noticing: one copy took the FIRST numeric member of a value
      # object, the other only unwrapped when there was EXACTLY ONE — so a
      # value object with two numeric members compared as a number on one
      # path and as a whole Hash on the other.
      #
      # The callers still differ in how they REACH a value — one takes a
      # registry argument, the other closes over `@registry`; one digs the
      # field through `FieldPath`, the other is handed it — so they keep
      # their own resolution and share only the comparison itself.
      module Comparison
        module_function

        # A value object compared as a scalar, when which scalar is meant
        # is not in doubt. Exactly one numeric member is unambiguous; a
        # single-member value object is unambiguous whatever its type.
        # Anything else is returned UNCHANGED rather than guessed at — two
        # numeric members give no reason to prefer either, and picking the
        # first silently compares a field the author never named.
        #
        # A declaration naming an ambiguous value object is refused when
        # the bluebook loads (`AggregateBuilder`'s own query-field seal),
        # so this branch is a backstop rather than the primary guard: which
        # member is meant is knowable at declaration time, and a refusal
        # naming the candidates is worth more than any runtime reading.
        def comparable(value)
          value = value.to_h if value.is_a?(Runtime::Value)
          return value unless value.is_a?(Hash)

          numerics = value.values.select { |field| field.is_a?(Numeric) }
          return numerics.first if numerics.size == 1
          return value.values.first if value.size == 1

          value
        end

        # Which members a value object offers a scalar comparison, for a
        # refusal that can name them. Empty when the value object is
        # unambiguous — nothing to report.
        def ambiguous_members(value_object)
          numerics = value_object.attributes.select { |a| NUMERIC_TYPES.include?(a.type.to_s) }
          return [] if numerics.size == 1 || value_object.attributes.size == 1

          value_object.attributes.map(&:name)
        end

        NUMERIC_TYPES = %w[Integer Float Numeric].freeze

        def holds?(operation, held, want, registry: nil)
          # A NULL SATISFIES NO COMPARISON — NullPolicy.unmatchable? owns
          # the rule and the reasoning, including why `none_in_state` is
          # exempt from it.
          return false if NullPolicy.unmatchable?(operation, held, want)

          case operation.to_s
          when "eq"       then held == want
          when "ne"       then held != want
          when "lt"       then ordered?(held, want) && held < want
          when "lte"      then ordered?(held, want) && held <= want
          when "gt"       then ordered?(held, want) && held > want
          when "gte"      then ordered?(held, want) && held >= want
          when "in"       then any_member_in?(held, want)
          when "contains" then contains?(held, want)
          when "none_in_state" then none_in_state?(held, want, registry)
          else
            # Every declared comparator has a `when` above (Vocabulary::
            # QueryComparator, held equal to this list by
            # spec/vocabulary_table_spec) — this is not a real runtime
            # path today, only a backstop against the day a tenth
            # comparator reaches the grammar and this method doesn't
            # grow to match. Silently reading an unrecognized comparator
            # as `eq` is exactly the failure this table already shipped
            # once (see this file's own header) — an operator this
            # method can't evaluate must refuse, not guess.
            raise Runtime::WiringError, "no comparator handles #{operation.to_s.inspect} — add one before declaring it"
          end
        end

        # gt/gte/lt/lte are numeric-only and silently false otherwise — a
        # where-clause never raises the way a given does, and that contract
        # predates the extraction (lt was already exactly this permissive).
        def ordered?(held, want) = held.is_a?(Numeric) && want.is_a?(Numeric)

        # `in` reads a comma-separated list — a real Array survives
        # untouched (a bluebook's own in-process value, before any wire
        # serialisation), each element unwrapped the same way a scalar
        # field is. This is `in`'s reading of ITS ARGUMENT (a caller may
        # legitimately pass "a,b,c" meaning "any of these") — unrelated to
        # `contains`, which reads the STORED field. See `contains?`.
        def members(value)
          return value.map { |element| comparable(element).to_s } if value.is_a?(Array)

          value.to_s.split(",").map(&:strip)
        end

        # A folded reference hop asks whether the locally-held identity is
        # among the matching target identities. A has_many relationship holds
        # several identities, so the same question becomes an intersection:
        # does ANY held identity occur in the wanted set? Scalar `in` retains
        # its existing one-candidate behavior.
        def any_member_in?(held, want)
          wanted = members(want)
          candidates = held.is_a?(Array) ? held : [held]

          candidates.any? { |candidate| wanted.include?(comparable(candidate).to_s) }
        end

        # `contains` means two different things depending on what is HELD —
        # real ELEMENT membership for a `list_of` field (a genuine Array
        # arrives already, one element one member, nothing to split), and
        # plain SUBSTRING for anything else. It used to fall through to
        # `members`' comma-split for the scalar case too, silently reading
        # a free-text field's own comma as a separator — which the SQL
        # side's `instr`/`position` never did, so the two disagreed the
        # moment a scalar's real content held a comma. Matching SQL's
        # substring reading here keeps every engine answering `contains`
        # identically for the same declared field.
        def contains?(held, want)
          return members(held).include?(want.to_s) if held.is_a?(Array)

          held.to_s.include?(want.to_s)
        end

        # A CROSS-AGGREGATE ANTI-JOIN — `where ref: { none_in_state:
        # "Claim:held" }` holds when NO record in the named aggregate,
        # keyed by this record's own field value, is in the named state.
        # No registry — no way to look the target up — reads as "not
        # excluded", the same graceful default a missing record already
        # falls back to. The target is searched by bare name across every
        # loaded domain; ambiguity (two domains declaring one name) picks
        # the first match rather than refusing, since a where-clause never
        # raises (see `ordered?`).
        def none_in_state?(held, want, registry)
          return true unless registry

          aggregate_name, state = want.to_s.split(":", 2)
          target = find_aggregate_by_name(registry, aggregate_name)
          return true unless target

          target_domain, target_ir = target
          record = registry.repository(target_domain, target_ir).find(held)
          return true unless record

          comparable(record.state[:state]) != state
        end

        def find_aggregate_by_name(registry, name)
          registry.bluebooks.each do |domain, bluebook|
            aggregate = bluebook.aggregates.find { |a| a.hecks_name == name }
            return [domain, aggregate] if aggregate
          end
          nil
        end
      end
    end
  end
end
