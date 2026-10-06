require_relative "../rendering"
require_relative "errors"
require_relative "value"
require_relative "refusal_wording"
require_relative "tenant_scope"
require_relative "../ports/query/in_memory"
require_relative "../query_specification/field_path"
require_relative "read_model_interpreter/head_ordering"
require_relative "read_model_interpreter/shaping"
require_relative "read_model_interpreter/reductions"

module Hecks
  module Runtime
    # Interprets one declared `read_model`: resolves its `include`d heads and applies any
    # `group_by` or reduction (`REDUCTION_WORD`), preferring a native SQLite path when it can.
    class ReadModelInterpreter
      include HeadOrdering
      include Shaping
      include Reductions

      # The word each non-`count` reduction ivar reads back as in a refusal message.
      REDUCTION_WORD = {
        median_field: "median", sum_field: "sum", avg_field: "avg", min_field: "min",
        max_field: "max", percentile_field: "percentile", any_field: "any", all_field: "all"
      }.freeze

      # `sum`/`avg` refuse a Float field (ADR 0078): summing floats cannot be made to agree,
      # byte for byte, between Ruby and Rust, so v1 admits only the Integer case.
      INTEGER_ONLY_REDUCTIONS = %i[sum_field avg_field].freeze
      BOOLEAN_REDUCTIONS = %i[any_field all_field].freeze

      # One read model run: where it runs, the model after tenant scoping, and what the heads
      # need to be read: the reference's id and the heads a `where` or `order` applies to.
      Request = Struct.new(:domain, :bluebook, :model, :args, :rootless, :reference_id, :eligible)

      # @param registry [Runtime::Registry] the booted registry whose repositories
      #   this interpreter reads
      def initialize(registry) = @registry = registry

      # Runs one declared read model and returns its projected rows.
      # @param domain [String, Symbol] the domain the read model is declared in
      # @param model [Bluebook::ReadModel] the read model to run
      # @param args [Hash] the query's declared arguments
      # @return [Array<Hash>] a one-element array of head name => projected rows
      # @raise [Runtime::TypeMismatch] if a reference is a whole object
      # @raise [Runtime::NotFound] if the reference argument names no record
      # @raise [KeyError] if a rooted read model is asked without its reference argument
      # @raise [ArgumentError] if `group_by` or a reduction names an undeclared field, or one
      #   of the wrong type
      # @raise [Runtime::InvariantViolation] if two rows collide on a full `group_by` key
      # @raise [Runtime::WiringError] if the aggregate's repository cannot be resolved
      def call(domain, model, args)
        project(domain, model, args)
      end

      private

      # The root-first, native-SQLite, join ordering is the order of these steps: refuse a whole
      # object reference, scope by tenant, try the adapter's own path, then read the heads.
      def project(domain, model, args)
        request = build_request(domain, model, args)
        repository = native_repository(request)
        return repository.query_read_model(domain, request.model, args, request.bluebook) if repository

        shape_heads(request.model, request.bluebook, collect_heads(request))
      end

      def build_request(domain, model, args)
        bluebook = @registry.bluebook(domain)
        rootless = model.reference_target.nil?
        # Refused before the adapter early-return, so both paths refuse identically
        # rather than one silently opening a wrapped reference the other reads whole.
        refuse_object_reference(model, args) unless rootless
        reference_id = reference(args.fetch(model.reference_name)) unless rootless
        # Computed off the original model, before TenantScope wraps it, so this
        # reflects what the bluebook author declared, not the synthetic tenant
        # clause added underneath (ADR 0055; `on:` allows more than one head).
        eligible = model.filtered_head_names
        Request.new(domain, bluebook, TenantScope.apply(model, args), args, rootless, reference_id, eligible)
      end

      # The repository whose adapter answers the read model itself, when one does. A rootless
      # model, or one declaring `group_by` or any reduction, always runs the in-process loop
      # — none of those are pushed down into `query_read_model`, a known limit, not a silent one.
      def native_repository(request)
        model = request.model
        return nil if request.rootless || model.group_by.any? || model.reducing?

        repository = @registry.read_repository(request.domain, request.bluebook.aggregate(model.reference_target))
        repository if repository.respond_to?(:query_read_model) && repository.adapter.respond_to?(:query_read_model)
      end

      # The rows of every head, by the name the answer gives it. Root heads run first regardless
      # of declared `include` order — a many-side head declared before its root would otherwise
      # match against an empty `projected`. `partition`, not `sort_by`, which is not guaranteed
      # stable.
      def collect_heads(request)
        projected = []
        rows_by_as = {}
        ordered_heads(request).each do |head|
          rows = restrict_rows(request, head, head_rows(request, head, projected))
          projected << { aggregate: head[:aggregate], rows: rows }
          rows_by_as[head[:as]] = head[:many] ? rows : rows.first
        end
        rows_by_as
      end

      def ordered_heads(request)
        model = request.model
        root_heads, other_heads = model.aggregate_heads.partition { |head| head[:aggregate] == model.reference_target }
        root_heads + order_other_heads(request.bluebook, root_heads, other_heads)
      end

      def head_rows(request, head, projected)
        if head[:aggregate] == request.model.reference_target
          [fetch(request.bluebook, request.domain, head[:aggregate], request.reference_id)]
        elsif request.rootless
          # A rootless model has no root to FK-match against, so each head
          # reads independently; there is no DSL for cross-joining rootless
          # heads together, a deliberate scope limit, not a gap to grow into.
          head_records(request, head)
        else
          matching(head_records(request, head)) do |record|
            references_projected?(request.bluebook, head, record, projected)
          end
        end
      end

      def head_records(request, head)
        records(request.bluebook, request.domain, head[:aggregate])
      end

      # Whether `record` holds a reference to a row of a head already read.
      def references_projected?(bluebook, head, record, projected)
        projected.any? do |source|
          reference_fields(bluebook.aggregate(head[:aggregate]), source[:aggregate]).any? do |field|
            source[:rows].any? { |parent| reference(record[field]) == parent.id }
          end
        end
      end

      # Applies the model's own `where`/`order`/`limit` to a head the clause names.
      def restrict_rows(request, head, rows)
        return rows unless request.eligible.include?(head[:as])

        Ports::Query::InMemory.execute(rows, request.model.options_for(head[:as]), request.args)
      end

      def fetch(bluebook, domain, aggregate_name, id)
        @registry.read_repository(domain, bluebook.aggregate(aggregate_name)).find(id) ||
          raise(NotFound, RefusalWording.render_site("NotFound", "read_model_reference_missing",
                                                     aggregate: aggregate_name, offered: Rendering.describe(id)))
      end

      def records(bluebook, domain, aggregate_name)
        aggregate = bluebook.aggregate(aggregate_name)
        aggregate ? @registry.read_repository(domain, aggregate).all : []
      end

      # A reference has no path of its own (unlike an identity), so `Value.scalar`
      # refuses a composite rather than guessing which field was meant.
      def refuse_object_reference(model, args)
        offered = args.fetch(model.reference_name, nil)
        return unless offered.is_a?(Hash) || offered.is_a?(Value)

        raise TypeMismatch,
              RefusalWording.render_site("TypeMismatch", "read_model_object_reference",
                                         query: model.query_name, field: model.reference_name)
      end

      # A reference is the id, in the argument and in the stored row alike.
      def reference(value) = value.to_s

      def matching(records, &) = records.select(&).sort_by(&:id)
      def row(record) = record.to_h
    end
  end
end
