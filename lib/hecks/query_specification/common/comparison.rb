require_relative "null_policy"
require_relative "../../runtime/value"

module Hecks
  module QuerySpecification
    module Common
      # **The one comparator table**. There were two, near-identical copies of
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
      # silently excluded every row. And `comparable` diverged without
      # anyone noticing: one copy took the first numeric member of a value
      # object, the other only unwrapped when there was exactly one — so a
      # value object with two numeric members compared as a number on one
      # path and as a whole Hash on the other.
      #
      # The callers still differ in how they reach a value — one takes a
      # registry argument, the other closes over `@registry`; one digs the
      # field through `FieldPath`, the other is handed it — so they keep
      # their own resolution and share only the comparison itself.
      module Comparison
        module_function

        # Unwraps a value object to the one scalar a comparison can mean.
        #
        # A value object compared as a scalar, when which scalar is meant
        # is not in doubt. Exactly one numeric member is unambiguous; a
        # single-member value object is unambiguous whatever its type.
        # Anything else is returned unchanged rather than guessed at — two
        # numeric members give no reason to prefer either, and picking the
        # first silently compares a field the author never named.
        #
        # A declaration naming an ambiguous value object is refused when
        # the bluebook loads (`AggregateBuilder`'s own query-field seal),
        # so this branch is a backstop rather than the primary guard: which
        # member is meant is knowable at declaration time, and a refusal
        # naming the candidates is worth more than any runtime reading.
        #
        # @param value [Runtime::Value, Hash, Object, nil] a held or wanted value; a
        #   `Runtime::Value` is read through its `to_h`
        # @return [Object, nil] the sole numeric member, or the sole member, of a Hash-shaped
        #   value; otherwise `value` unchanged (a `Runtime::Value` comes back as its Hash)
        def comparable(value)
          value = value.to_h if value.is_a?(Runtime::Value)
          return value unless value.is_a?(Hash)

          numerics = value.values.grep(Numeric)
          return numerics.first if numerics.size == 1
          return value.values.first if value.size == 1

          value
        end

        # Lists the members a value object offers a scalar comparison, for a
        # refusal that can name them. Empty when the value object is
        # unambiguous — nothing to report.
        #
        # @param value_object [Class<Bluebook::ValueObject>] the declared shape (a subclass
        #   minted by `Bluebook::ValueObject.declare`, closed sets included) a query field names
        # @return [Array<Symbol>] every attribute name when no single member can be meant;
        #   `[]` when there is exactly one attribute, or exactly one typed `Integer`,
        #   `Float` or `Numeric`
        def ambiguous_members(value_object)
          numerics = value_object.attributes.select { |a| NUMERIC_TYPES.include?(a.type.to_s) }
          return [] if numerics.size == 1 || value_object.attributes.size == 1

          value_object.attributes.map(&:name)
        end

        NUMERIC_TYPES = %w[Integer Float Numeric].freeze

        # Decides whether one where-clause comparison holds between the value
        # a record holds and the value the query wants.
        #
        # A `case` over a closed, declared set (`Vocabulary::QueryComparator`,
        # held equal to this list by spec/vocabulary_table_spec — see the
        # `else` branch's own comment) is the whole point of the one
        # comparator table this file's header describes: one place naming
        # every comparator, not one method per comparator scattered across
        # a module.
        #
        # @param operation [Symbol, String] the comparator name: `eq`, `ne`, `lt`, `lte`,
        #   `gt`, `gte`, `in`, `contains` or `none_in_state`
        # @param held [Object, nil] the record's own value for the field; `nil` against a
        #   non-nil `want` satisfies no comparator except `none_in_state` (see
        #   `NullPolicy.unmatchable?`)
        # @param want [Object, nil] the value compared against; for `in` an Array or a
        #   comma-separated String, for `none_in_state` an `"Aggregate:state"` String
        # @param registry [Runtime::Registry, nil] used only by `none_in_state` to look the
        #   target aggregate up; `nil` makes that comparator hold
        # @return [Boolean] whether the comparison holds; an ordered comparator over a
        #   non-`Numeric` operand is `false`
        # @raise [Runtime::WiringError] if `operation` names no comparator in this table, or
        #   `none_in_state`'s target aggregate has no repository that can be wired
        # rubocop:disable-next Metrics/CyclomaticComplexity
        def holds?(operation, held, want, registry: nil)
          # A NULL satisfies no comparison — NullPolicy.unmatchable? owns
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

        # Checks that both operands of an ordered comparison are numbers.
        #
        # gt/gte/lt/lte are numeric-only and silently false otherwise — a
        # where-clause never raises the way a given does, and that contract
        # predates the extraction (lt was already exactly this permissive).
        #
        # @param held [Object, nil] the record's own value for the field
        # @param want [Object, nil] the value compared against
        # @return [Boolean] `true` only when both are `Numeric`
        def ordered?(held, want) = held.is_a?(Numeric) && want.is_a?(Numeric)

        # Reads a comparator's list operand as the Strings membership is tested against.
        #
        # `in` reads a comma-separated list — a real Array survives
        # untouched (a bluebook's own in-process value, before any wire
        # serialisation), each element unwrapped the same way a scalar
        # field is. This is `in`'s reading of its argument (a caller may
        # legitimately pass "a,b,c" meaning "any of these") — unrelated to
        # `contains`, which reads the stored field. See `contains?`.
        #
        # @param value [Array, String, Object, nil] an Array of elements, or anything whose
        #   `to_s` is a comma-separated list such as `"a, b,c"`
        # @return [Array<String>] one String per member: Array elements unwrapped through
        #   `comparable` then `to_s`; split parts stripped of surrounding whitespace; `[]`
        #   for `nil` or an empty String
        def members(value)
          return value.map { |element| comparable(element).to_s } if value.is_a?(Array)

          value.to_s.split(",").map(&:strip)
        end

        # Answers `in`: whether the held value, or any element of a held Array,
        # occurs in the wanted list.
        #
        # A folded reference hop asks whether the locally-held identity is
        # among the matching target identities. A has_many relationship holds
        # several identities, so the same question becomes an intersection:
        # does any held identity occur in the wanted set? Scalar `in` retains
        # its existing one-candidate behavior.
        #
        # @param held [Array, Object] the record's own value; an Array contributes each
        #   element as a candidate, anything else is the single candidate
        # @param want [Array, String, Object] the wanted set, read through `members`
        # @return [Boolean] whether any candidate, unwrapped through `comparable` and
        #   compared as a String, is a wanted member
        def any_member_in?(held, want)
          wanted = members(want)
          candidates = held.is_a?(Array) ? held : [held]

          candidates.any? { |candidate| wanted.include?(comparable(candidate).to_s) }
        end

        # Answers `contains`: element membership for a held Array, substring
        # for anything else.
        #
        # `contains` means two different things depending on what is held —
        # real element membership for a `list_of` field (a genuine Array
        # arrives already, one element one member, nothing to split), and
        # plain substring for anything else. The scalar case deliberately
        # stays out of `members`' comma-split: that silently reads a
        # free-text field's own comma as a separator — which the SQL
        # side's `instr`/`position` never does, so the two disagree the
        # moment a scalar's real content holds a comma. Matching SQL's
        # substring reading here keeps every engine answering `contains`
        # identically for the same declared field.
        #
        # @param held [Array, Object] the record's own value; anything but an Array is
        #   read through `to_s`
        # @param want [Object] the element or substring looked for, compared as its `to_s`
        # @return [Boolean] whether `held` has `want` as a member (Array) or a substring
        def contains?(held, want)
          return members(held).include?(want.to_s) if held.is_a?(Array)

          held.to_s.include?(want.to_s)
        end

        # Answers `none_in_state` by looking the held identity up in another
        # aggregate's repository and reading that record's state.
        #
        # **A cross-aggregate anti-join** — `where ref: { none_in_state:
        # "Claim:held" }` holds when no record in the named aggregate,
        # keyed by this record's own field value, is in the named state.
        # No registry — no way to look the target up — reads as "not
        # excluded", the same graceful default a missing record already
        # falls back to. The target is searched by bare name across every
        # loaded domain; ambiguity (two domains declaring one name) picks
        # the first match rather than refusing, since a where-clause never
        # raises (see `ordered?`).
        #
        # @param held [Object, nil] this record's own field value, used as the target
        #   record's identity
        # @param want [String, Symbol] `"Aggregate:state"` — the target aggregate's bare
        #   name and the excluded state, split on the first colon
        # @param registry [Runtime::Registry, nil] the booted registry to find the target
        #   aggregate and its repository in
        # @return [Boolean] `false` only when the target record exists and its lifecycle
        #   field (or `:state`, absent a lifecycle) equals the named state; `true` when
        #   there is no registry, no such aggregate or no such record
        # @raise [Runtime::WiringError] if the target aggregate's repository cannot be wired
        def none_in_state?(held, want, registry)
          return true unless registry

          aggregate_name, state = want.to_s.split(":", 2)
          target = find_aggregate_by_name(registry, aggregate_name)
          return true unless target

          target_domain, target_ir = target
          record = registry.repository(target_domain, target_ir).find(held)
          return true unless record

          # The field a state lives on, read from the target's own
          # declaration — not assumed to be literally named `state`. Every
          # `none_in_state` fixture this comparator originally shipped
          # with (spec/query_none_in_state_*_spec.rb) happens to declare a
          # plain `attribute :state, ...` rather than a real `lifecycle`,
          # which is how the previous hardcoded `record.state[:state]`
          # passed every one of them while being wrong for the shape this
          # whole comparator exists to answer about: a real state machine.
          # `lifecycle :field, default: ... do ... end` stores its state
          # under `field` (`Instance#assign_creation_attributes`'s own
          # `state[aggregate.lifecycle.field.to_sym] = ...`), and this
          # codebase's own convention overwhelmingly names that field
          # `status`, not `state` (`QualityControl::Clearance`'s own
          # `lifecycle :status` among many others) — so the hardcoded key
          # silently read `nil` from every real lifecycle-backed target,
          # comparable(nil) != state was true unconditionally, and
          # `none_in_state` against any lifecycle aggregate answered
          # "not excluded" for every row, always, no matter its actual
          # state. Found chasing `QualityControl::Bug.AwaitingClearance`
          # (qa/bluebook/quality_control.bluebook), which is exactly this
          # shape: `Clearance:green`/`Clearance:red` against a `lifecycle
          # :status` aggregate. Falls back to `:state` when the target
          # declares no lifecycle at all, so every existing fixture (a
          # plain attribute literally named `state`) keeps answering
          # exactly as before.
          field = target_ir.lifecycle&.field || :state
          comparable(record.state[field]) != state
        end

        # Searches every loaded domain for an aggregate by its bare name, taking
        # the first match in the registry's load order.
        #
        # @param registry [Runtime::Registry] the booted registry whose bluebooks are searched
        # @param name [String, nil] the aggregate's bare `hecks_name`, such as `"Claim"`
        # @return [Array(String, Bluebook::Aggregate), nil] the owning domain's name and the
        #   aggregate; `nil` when no loaded domain declares one by that name
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
