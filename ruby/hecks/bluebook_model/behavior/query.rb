# [antibody-exempt: ruby/hecks/bluebook_model/behavior/query.rb — kernel-
#  surface bluebook DSL query recorder. i226 wires hash-form comparators
#  (`where(field: { lt|lte|gt|gte|ne: value })`) on the Ruby side to
#  mirror parse_blocks.rs ; the IR's WhereOp already carries each
#  variant. Same retirement contract as parse_blocks.rs : exists to
#  enable consolidate.sh + rem_branch.sh retirement (i221 / i222).]

module Hecks
  module BluebookModel
    module Behavior

    # Hecks::BluebookModel::Behavior::Query
    #
    # Intermediate representation of a domain query -- a named, reusable lookup
    # defined in the DSL. Each query has a name and a block that uses the
    # query DSL (where, order, limit, etc.) to build results.
    #
    # i101 — Queries also expose structured `attributes`, `wheres`,
    # `order_by`, and `limit` extracted from the block by evaluating it
    # inside a QueryRecorder context. This is what lets the canonical IR
    # match Rust's first-class query IR byte-for-byte ; the runtime can
    # walk the structured fields without re-evaluating the Ruby block.
    #
    # The recorder is best-effort : blocks that use methods we don't
    # know about gracefully no-op (recorder.method_missing returns self
    # so chains keep flowing). If recording fails entirely, the
    # structured fields are empty and the Query falls back to the
    # legacy block-based path.
    #
    #   query = Query.new(name: "Classics", block: proc { where(style: "Classic") })
    #   query.name    # => "Classics"
    #   query.wheres  # => [#<WhereClause field="style" op="eq" value="Classic">]
    #   query.block   # => #<Proc>
    #
    class Query
      # @return [String] PascalCase query name (e.g. "Classics", "RecentOrders")
      # @return [Proc] block evaluated in the query DSL context at runtime;
      #   can call +where+, +order+, +limit+, and other query methods
      attr_reader :name, :block, :description,
                  :attributes, :wheres, :order_by, :limit

      # Creates a new Query IR node.
      #
      # @param name [String] PascalCase query name (e.g. "Classics")
      # @param block [Proc] callable that defines the query logic. Evaluated in
      #   a QueryBuilder context at runtime, with access to methods like +where+,
      #   +order+, +limit+, etc.
      # @return [Query]
      def initialize(name:, block:)
        @name = name
        @block = block
        @description = nil
        @attributes = []
        @wheres = []
        @order_by = nil
        @limit = nil
        record_block_structure! if block
      end

      private

      # Evaluate `block` inside a QueryRecorder so we capture the
      # structured intent (attributes / wheres / order_by / limit)
      # instead of just storing an opaque Proc. Errors during recording
      # are swallowed — the legacy block path still works.
      def record_block_structure!
        recorder = QueryRecorder.new
        # Map the block's positional params (e.g. `query "ByX" do |x| … end`)
        # to placeholder kwargs so `where(field: x)` records the kwarg-ref form.
        params = block.parameters.map { |_, name| name }.compact
        if params.empty?
          recorder.instance_eval(&block)
        else
          stubs = params.map { |p| QueryRecorder::Kwarg.new(p) }
          @attributes.concat(params.map { |p|
            BluebookModel::Structure::Attribute.new(name: p, type: String)
          })
          recorder.instance_exec(*stubs, &block)
        end
        @description = recorder.recorded_description
        @wheres      = recorder.wheres
        @order_by    = recorder.recorded_order_by
        @limit       = recorder.recorded_limit
      rescue StandardError, ScriptError
        # Best-effort — leave fields empty, fall back to opaque block.
        @wheres   = []
        @order_by = nil
        @limit    = nil
      end
    end

    # Hecks::BluebookModel::Behavior::QueryRecorder
    #
    # Captures `where`, `order_by`, and `limit` calls from a query DSL
    # block into structured records. Used by Query#initialize to expose
    # the block's intent as structured IR so the canonical dump matches
    # Rust's first-class query IR.
    class QueryRecorder
      WhereClause = Struct.new(:field, :op, :value, keyword_init: true)
      OrderBy     = Struct.new(:field, :direction, keyword_init: true)
      LimitSpec   = Struct.new(:value, keyword_init: true)

      # Stand-in for a positional block parameter — captured into a
      # WhereClause as `:name` so the canonical IR matches Rust's
      # kwarg-ref form.
      class Kwarg
        attr_reader :name
        def initialize(name) = @name = name
        def to_s            = ":#{@name}"
      end

      attr_reader :wheres

      def initialize
        @description = nil
        @wheres = []
        @order_by = nil
        @limit = nil
      end

      # Accessors for the recorded ivars under names that don't collide
      # with the DSL methods `description` / `order_by` / `limit` (those
      # take args, so a bare attr_reader would shadow them and raise
      # ArgumentError when the host code reads the ivar).
      def recorded_description; @description; end
      def recorded_order_by;    @order_by;    end
      def recorded_limit;       @limit;       end

      # `description "Return the current count"` — human-readable goal.
      def description(text)
        @description = text.to_s
        self
      end

      # `where(field: value)` records each kwarg as a WhereClause.
      #
      # Two forms recognized (i226) :
      #
      #   where(field: value)              # eq form (default)
      #   where(field: { lt: value })      # comparator hash form
      #
      # The comparator hash form uses a single-key inner hash where the
      # key is one of :lt / :lte / :gt / :gte / :ne / :eq. Anything else
      # falls through to eq with the literal hash as the value (best-
      # effort — the parity test gates the canonical shapes).
      COMPARATOR_OPS = {
        lt:  "lt",  "lt"  => "lt",
        lte: "lte", "lte" => "lte",
        gt:  "gt",  "gt"  => "gt",
        gte: "gte", "gte" => "gte",
        ne:  "ne",  "ne"  => "ne",
        eq:  "eq",  "eq"  => "eq",
        in:  "in",  "in"  => "in",
        none_in_state: "none_in_state", "none_in_state" => "none_in_state",
        contains: "contains", "contains" => "contains",
      }.freeze

      def where(**conditions)
        conditions.each do |field, value|
          op, inner = extract_comparator(value)
          @wheres << WhereClause.new(
            field: field.to_s,
            op:    op,
            value: inner.is_a?(Array) ? inner.map(&:to_s).join(",") : format_value(inner),
          )
        end
        self
      end

      # If `value` is a single-key Hash whose key names a comparator op,
      # return [op_string, inner_value]. Otherwise return ["eq", value]
      # so the bare-form keeps the existing semantics.
      def extract_comparator(value)
        if value.is_a?(Hash) && value.size == 1
          k, v = value.first
          if (op = COMPARATOR_OPS[k])
            return [op, v]
          end
        end
        ["eq", value]
      end

      # `order_by :field` (asc by default) or `order_by :field, :desc`.
      def order_by(field, direction = :asc)
        @order_by = OrderBy.new(
          field:     field.to_s,
          direction: direction.to_s,
        )
        self
      end

      # `limit 10` or `limit :max_results` — same literal-or-kwarg
      # pattern as where-clause values.
      def limit(value)
        @limit = LimitSpec.new(value: format_value(value))
        self
      end

      # Best-effort fallthrough — silently no-op so chained calls don't
      # raise (e.g. `where(...).order(:name)` when `order` isn't recognized).
      def method_missing(_name, *_args, **_kwargs, &_block)
        self
      end

      def respond_to_missing?(_name, _include_private = false)
        true
      end

      private

      def format_value(v)
        case v
        when Kwarg     then ":#{v.name}"
        when Symbol    then ":#{v}"
        when String    then v
        when Numeric, TrueClass, FalseClass then v.to_s
        when nil       then ""
        else v.to_s
        end
      end
    end
    end
  end
end
