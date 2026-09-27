module Hecks
  module Bluebook
    module ModelCheck
      # The opt-in `client` profile: refuses the bluebook constructs this
      # repository already knows produce a silently wrong answer, so a client
      # domain cannot reach one without being told.
      #
      # ## What it is not
      #
      # It fixes nothing. Each rule below names a bug that is still open and
      # stops a domain reaching it unnoticed; when the bug is fixed the rule
      # goes with it. `spec/model_check_client_profile_spec.rb` holds a probe
      # per rule that runs the buggy code and fails the moment the bug stops
      # reproducing, naming the rule to delete.
      #
      # ## The rules
      #
      # - `:client_group_by_row_drop` — a `group_by` whose fields do not include
      #   the grouped aggregate's whole identity. Rows sharing a key path are
      #   collapsed to the first, on every adapter (docs/decisions/0061).
      # - `:client_native_read_model` — a read model the SQLite projection
      #   answers natively, where every other path answers it in process
      #   (docs/1.0-readiness.md, "Known gaps at 1.0", item 2).
      module ClientProfile
        # Adapters whose Ruby class implements `query_read_model`, which is what
        # makes `ReadModelInterpreter#project` take the native path. The spec
        # checks this list against the adapter classes themselves.
        NATIVE_READ_MODEL_ADAPTERS = %w[SqliteProjection].freeze

        GROUP_BY_TRACKER = "docs/decisions/0061-query-dsl-aggregation-count-sum-group-by.md".freeze
        NATIVE_READ_MODEL_TRACKER = "docs/1.0-readiness.md (Known gaps at 1.0, item 2)".freeze

        module_function

        # Runs every client-profile rule over one chapter.
        #
        # @param bluebook [Bluebook::Chapter] the assembled chapter to check
        # @param hecksagon [Bluebook::Hecksagon, nil] the chapter's sibling wiring file; without
        #   one no aggregate is projected, so the native-read-model rule has nothing to find
        # @return [Array<ModelCheck::Finding>] one error-severity finding per construct refused
        def call(bluebook, hecksagon: nil)
          bluebook.read_models.flat_map do |model|
            group_by_findings(bluebook, model) + native_read_model_findings(model, hecksagon)
          end
        end

        # Refuses a `group_by` that cannot prove each of its key paths names one row.
        #
        # The interpreter's `nest` keeps `stripped.first` per key path, whichever adapter
        # supplied the rows, because a `group_by` model never reaches the native path. Grouping
        # by the aggregate's whole identity is the one shape that cannot collide.
        #
        # @param bluebook [Bluebook::Chapter] the chapter the read model is declared in
        # @param model [Bluebook::ReadModel] the read model to inspect
        # @return [Array<ModelCheck::Finding>] one finding, or `[]` when `model` declares no
        #   `group_by` or groups by its aggregate's whole identity
        def group_by_findings(bluebook, model)
          return [] if model.group_by.empty? || groups_by_identity?(bluebook, model)

          [finding(:client_group_by_row_drop, model.name,
                   "group_by #{model.group_by_fields.map(&:inspect).join(', ')} does not cover the grouped " \
                   "aggregate's whole identity, so rows sharing a key path are silently reduced to the " \
                   "first. Tracked in #{GROUP_BY_TRACKER}.")]
        end

        # Refuses a read model that the SQLite projection would answer natively.
        #
        # Mirrors the fork in `ReadModelInterpreter#project`: a rooted model with no `group_by`,
        # `count` or `median` reads through `read_repository`, which is a projection repository
        # only for an aggregate with a `projected_by` bind. Whether that projection is current
        # is only known at run time (`Registry#projection_current?`), so a model eligible here
        # can also silently run in process.
        #
        # @param model [Bluebook::ReadModel] the read model to inspect
        # @param hecksagon [Bluebook::Hecksagon, nil] the wiring holding the `projected_by` binds
        # @return [Array<ModelCheck::Finding>] one finding, or `[]` when the model cannot be
        #   pushed down
        def native_read_model_findings(model, hecksagon)
          return [] unless hecksagon && native_eligible?(model)

          bind = hecksagon.binds_for(model.reference_target, Ports::Projection::VERB).first
          return [] unless bind && NATIVE_READ_MODEL_ADAPTERS.include?(bind.adapter.to_s)

          [finding(:client_native_read_model, model.name,
                   "#{model.reference_target} is projected_by #{bind.adapter.inspect}, so this read model " \
                   "is answered by SQL when the projection is current and by the in-process loop when it " \
                   "is not, and nothing checks the two agree. Tracked in #{NATIVE_READ_MODEL_TRACKER}.")]
        end

        # Reports whether a model's shape sends it down the native path in `#project`.
        #
        # @param model [Bluebook::ReadModel] the read model to inspect
        # @return [Boolean] true for a rooted model declaring no `group_by`, `count` or `median`
        def native_eligible?(model)
          !model.reference_target.nil? && model.group_by.empty? && !model.count? && !model.median_field
        end

        # Reports whether a `group_by` names every identity path of the aggregate it groups.
        #
        # @param bluebook [Bluebook::Chapter] the chapter the read model is declared in
        # @param model [Bluebook::ReadModel] a read model that declares a `group_by`
        # @return [Boolean] false when the many-side aggregate is not a top-level aggregate or
        #   declares no identity, since uniqueness cannot then be shown
        def groups_by_identity?(bluebook, model)
          target = model.aggregate_heads.find { |head| head[:many] }
          aggregate = target && bluebook.aggregate(target[:aggregate])
          return false unless aggregate

          identity = Array(aggregate.identity_heads).map(&:to_sym)
          !identity.empty? && (identity - model.group_by_fields.map(&:to_sym)).empty?
        end

        # Builds one error-severity finding of this profile.
        #
        # @param kind [Symbol] the finding's kind, one of the `:client_*` rules above
        # @param subject [String] the read model or `Domain::Aggregate` the finding is about
        # @param message [String] what was found, why it is refused, and where it is tracked
        # @return [ModelCheck::Finding] an `:error` finding
        def finding(kind, subject, message)
          ModelCheck::Finding.new(kind: kind, severity: :error, subject: subject, message: message)
        end
      end
    end
  end
end
