module RustProjection
  module Projector
    module_function

    # Port of `Runtime::DependencyPlanning::Analyzer#call`'s
    # `complete_state? && state_independent?` predicate — see BUG#28
    # (QualityControl ledger) and `rust/src/kernel/dispatch.rs`'s own
    # `Hydrate::Create` comment for the full story: Ruby defers a
    # creating command's `AlreadyExists` check to save time (mirroring
    # `atomic_put(insert_only: true)`) exactly when this predicate is
    # true — AFTER `enforce_givens`/`admissible_transition`/`apply_
    # mutations`/`enforce_ensures`/`enforce_invariants` have all already
    # run, rather than eagerly at hydration. `rust/src/kernel/dispatch.rs`
    # needs the SAME classification, at codegen time, to generate the
    # matching deferred-check shape.
    #
    # DELIBERATELY A SEPARATE PORT, operating on the exported IR HASH
    # shape (attributes/mutations/givens/ensures ASTs/lifecycle — the
    # same shape every other `rust/project/*.rb` predicate already reads;
    # `creates_owner?`/`list_attr_creation_optional?`, mutations.rb,
    # chief among them) rather than a shared call into
    # `Runtime::DependencyPlanning::Analyzer` itself. Two reasons, both
    # real:
    #
    #   1. THAT ANALYZER NEEDS LIVE `Bluebook::Aggregate`/`Bluebook::
    #      Command` OBJECTS (`.attributes`, `.givens`, `.mutations`, each
    #      a real Struct/rule with parsed-AST accessors) — every
    #      `rust/project/*.rb` file, by design (see rust/project.rb's own
    #      header on the JSON round-trip), works ONLY off the plain
    #      JSON-round-tripped `ir.json` Hash shape, so this generator
    #      never depends on live Ruby object/Symbol behavior. Reusing the
    #      live Analyzer here would be the one exception.
    #   2. `rust/codegen` (Rust-native codegen — `hecks-codegen`) needs
    #      the IDENTICAL classification too, and cannot call INTO Ruby at
    #      all. Baking the answer into `ir.json` as a new precomputed
    #      field (rather than each codegen independently deriving it from
    #      already-exported facts) would mean `rust/parser`'s own
    #      `hecks-parse` — a THIRD, separate IR producer with no access
    #      to Ruby's Analyzer either — would ALSO need to learn to
    #      compute and emit it, for `bin/project_rust`'s opt-in
    #      `HECKS_PARSER=rust HECKS_CODEGEN=rust` pipeline
    #      (`spec/project_rust_pipeline_spec.rb`) to keep agreeing with
    #      the default path. Independent re-derivation from data every
    #      producer ALREADY emits (mirroring how `creates?`/`references.
    #      nil?` itself is independently re-derived in Rust, never
    #      injected — see `creates_owner?`'s own header) sidesteps that
    #      gap entirely: `rust/codegen`'s own port
    #      (`rust/codegen/src/dependency_planning.rs`) reads ir.json
    #      directly, so the opt-in all-Rust pipeline gets this for free
    #      the moment `hecks-codegen` does, with zero change needed to
    #      `hecks-parse`.
    #
    # `spec/codegen_parity_spec.rb`'s existing whole-file byte-identity
    # check (banking, pizzas, governance, ... every `WHOLE_FILE_MEMBERS`
    # entry) is what proves this Ruby port and the Rust one
    # (`dependency_planning.rs`) agree with EACH OTHER;
    # `spec/rust_project/dependency_planning_spec.rb` (new) additionally
    # proves THIS port agrees with the REAL `Runtime::DependencyPlanning
    # ::Analyzer` across the whole live example-domain corpus, not just
    # the handful of IR fixtures the parity spec happens to enumerate.
    #
    # ONLY MEANINGFUL for a command `creates_owner?` already answered
    # `true` for — callers are expected to check that first, same as
    # `list_attr_creation_optional?`'s own callers do; never true for an
    # entity-owned command (`emit_command`'s own caller never reaches
    # this for one — an entity command is never `creates_owner?`).
    def state_independent_creation?(aggregate, command, value_objects_by_name)
      owner_fields = creation_owner_fields(aggregate)
      payload_fields = command[:attributes].to_set { |a| a[:name].to_s }

      known_writes, disqualified = creation_known_writes(aggregate, command, owner_fields, payload_fields, value_objects_by_name)
      return false if disqualified
      return false unless owner_fields.subset?(known_writes)

      rules = command[:givens].map { |rule| [rule, :before] } +
              command[:ensures].map { |rule| [rule, :after] } +
              aggregate[:invariants].map { |rule| [rule, :after] }

      rules.all? do |rule, phase|
        creation_rule_state_independent?(rule[:ast], phase, payload_fields, owner_fields)
      end
    end

    # `Runtime::DependencyPlanning::Analyzer#initialize`'s own
    # `@owner_fields` — every field a fresh `Instance.new` on this
    # aggregate carries: its declared attributes, its lifecycle field (if
    # any), and its `projects` fields (S12, ADR 0025 — a projected field
    # is owner state too, even though nothing here writes it via a
    # declared mutation; `CommandInterpreter#seed_projected_fields`
    # populates it outside this analysis entirely, same as the live
    # Analyzer's own comment on this exact point explains).
    def creation_owner_fields(aggregate)
      fields = aggregate[:attributes].to_set { |a| a[:name].to_s }
      fields << aggregate[:lifecycle][:field].to_s if aggregate[:lifecycle]
      Array(aggregate[:projected_fields]).each { |field| fields << field[:name].to_s }
      fields
    end

    # `analyze_initial_state` + `analyze_mutations` + `analyze_lifecycle`,
    # ported together (all three build the SAME `known_writes` set before
    # any given/ensures/invariant rule is analyzed, so nothing after this
    # point can add to it — analyzed in that exact order, faithfully).
    # Returns `[known_writes, disqualified]` — `disqualified` collapses
    # the live Analyzer's own separate `unresolved` bookkeeping into one
    # boolean, since this port only ever needs the FINAL conjunction
    # (`complete_state? && state_independent?`), never the two facts
    # reported separately.
    def creation_known_writes(aggregate, command, owner_fields, payload_fields, value_objects_by_name)
      known = Set.new
      aggregate[:attributes].each do |attr|
        known << attr[:name].to_s if creation_deterministic_initial_value?(attr, value_objects_by_name)
      end
      known << aggregate[:lifecycle][:field].to_s if aggregate[:lifecycle]

      # `analyze_lifecycle`'s own `state_reads << lifecycle.field if
      # command.from` — a creating command guarded by a lifecycle `from:`
      # state has no prior state to check (`return unless lifecycle`
      # guards the live method the same way here).
      disqualified = command[:from] && aggregate[:lifecycle] ? true : false

      command[:mutations].each do |mutation|
        target = mutation[:target].to_s
        unless owner_fields.include?(target)
          disqualified = true
          next
        end

        case creation_mutation_outcome(mutation, payload_fields, owner_fields)
        when :known then known << target
        when :unresolved then disqualified = true
        end
      end

      [known, disqualified]
    end

    # One mutation's own outcome — `:known` (contributes to `known_
    # writes`), `:unresolved` (disqualifying), or `:state_read` (neither:
    # a genuine prior-state read, or a STATEFUL op that never contributes
    # to `known_writes` at all — see the `append`/arithmetic branches'
    # own comments below for why leaving `target` out of `known_writes`
    # is already enough in both cases, no separate tracking needed).
    def creation_mutation_outcome(mutation, payload_fields, owner_fields)
      case mutation[:op].to_s
      when "set"
        creation_classify_source(mutation[:source], payload_fields, owner_fields)
      when "append"
        # STATEFUL (`Runtime::DependencyPlanning::Analyzer::STATEFUL_
        # MUTATIONS`) — never contributes to `known_writes` (only `:set`
        # does, in the live Analyzer's own `analyze_mutations`). Each
        # field value is still walked, mirroring `analyze_source?`'s own
        # Hash recursion over an append's `fields:` — only an undeclared
        # source name disqualifies here.
        creation_append_outcome(mutation[:fields], payload_fields, owner_fields)
      when "increment", "decrement", "multiply", "clamp", "remove"
        # STATEFUL, same reasoning as `append` — no real corpus creating
        # command declares one (there is nothing to increment on a
        # record that doesn't exist yet).
        :state_read
      else
        :unresolved
      end
    end

    def creation_append_outcome(fields, payload_fields, owner_fields)
      fields.each_value do |wire_value|
        parsed = append_field_source(wire_value)
        next unless parsed.is_a?(Symbol)

        return :unresolved if creation_classify_symbol(parsed.to_s, payload_fields, owner_fields) == :unresolved
      end

      :state_read
    end

    # `deterministic_initial_value?`, read directly: true for a list or
    # optional attribute, or one with a non-nil `default:`; otherwise
    # true only when the attribute's own type names a value object EVERY
    # one of whose OWN attributes already has a non-nil default.
    def creation_deterministic_initial_value?(attr, value_objects_by_name)
      return true if [attr[:list], attr[:optional], !attr[:default].nil?].any?

      vo = value_objects_by_name[attr[:type]]
      return false unless vo

      vo[:attributes].all? { |field| !field[:default].nil? }
    end

    # `analyze_source?`'s `when Symbol` branch, by NAME: `:known` (a
    # command payload argument), `:state_read` (a genuine owner-field
    # read — the live Analyzer's own `state_reads <<`, `false`), or
    # `:unresolved` (neither — a build-time-refused shape in practice,
    # ported faithfully anyway).
    def creation_classify_symbol(name, payload_fields, owner_fields)
      return :known if payload_fields.include?(name)
      return :state_read if owner_fields.include?(name)

      :unresolved
    end

    # `analyze_source?`, ported for a `:set`/arithmetic mutation's own
    # TOP-LEVEL `source:` (the `classified_source` shape — `{kind:,
    # name:/value:}`), never the `fields:` shape an append carries
    # (`creation_known_writes`'s own `append` branch handles that
    # separately, via `append_field_source`/`Literal.read`, the same
    # decode `creates_owner?`/`mark_append_optional_fields!` already use).
    #
    # `kind: "state"` (a `StateRef`, `state(:field)` on the wire) mirrors
    # the live Analyzer FAITHFULLY, not "correctly": `analyze_source?` has
    # no `when StateRef` branch at all, so a StateRef source falls to its
    # own `else -> true` — treated as KNOWN, never recorded as a state
    # read, even though it plainly reads the record's own prior field.
    # Reproduced here exactly rather than fixed, because fixing it would
    # make this port DISAGREE with the real Analyzer it exists to mirror
    # — the one thing this file must never do.
    def creation_classify_source(source, payload_fields, owner_fields)
      return creation_classify_symbol(source[:name].to_s, payload_fields, owner_fields) if source[:kind] == "argument"

      # "state" (a StateRef) and "literal" — and anything else this wire
      # shape could ever carry — all resolve to :known; see this method's
      # own header for why "state" is grouped here rather than treated as
      # a real prior-state read.
      :known
    end

    # `analyze_rules` + `classify_path`, ported over the exported `ast`
    # JSON tree (`Expression::AstJson.rule_row`) rather than the live
    # parsed AST `ExpressionReads.paths` walks — the identical node
    # shapes (`"op" => "lookup"`/`"block_predicate"`, `"path"` segment
    # arrays), just JSON-Hash-shaped instead of Ruby Structs. `true` when
    # this ONE rule reads nothing that disqualifies state-independence;
    # `false` the moment it does (an unresolved path, or a genuine
    # prior-state read) — the caller's own `.all?` already short-circuits
    # correctly across every given/ensures/invariant rule.
    def creation_rule_state_independent?(ast, phase, payload_fields, owner_fields)
      creation_paths(ast, Set.new).all? do |path|
        creation_path_state_independent?(path, phase, payload_fields, owner_fields)
      end
    end

    # `DependencyPlanning::ExpressionReads.collect`, ported node-for-node
    # over the JSON `ast` shape: a `"lookup"` node's own `path` (unless
    # its root is a bound name — a `block_predicate`'s own `param`), a
    # `"block_predicate"` node's `receiver` PLUS its `predicate` (with
    # `param` newly bound there only), and every other node's own values,
    # walked generically — the exact same `Struct`/`Array`/else shape the
    # live `collect` falls through to for every other node kind (Or/And/
    # Not/Compare/Include/Resolve and the rest), never hand-listed.
    def creation_paths(node, bound_names)
      case node
      when ::Hash
        case node["op"]
        when "lookup"
          root = node["path"].first.to_s
          bound_names.include?(root) ? [] : [node["path"].join(".")]
        when "block_predicate"
          creation_paths(node["receiver"], bound_names) +
            creation_paths(node["predicate"], bound_names | [node["param"].to_s])
        else
          node.each_value.flat_map { |value| creation_paths(value, bound_names) }
        end
      when ::Array
        node.flat_map { |value| creation_paths(value, bound_names) }
      else
        []
      end
    end

    # `classify_path`, ported: `parent.X`/`old.X` are ALWAYS disqualifying
    # (an aggregate-root command's own `root_owner_fields` equals
    # `owner_fields` — this port only ever runs for aggregate-root
    # creating commands, never an entity-owned one, so the live
    # Analyzer's own `root_aggregate:` distinction never applies here);
    # in the live Analyzer, `resolve_nested_state_read!` either records a
    # genuine state read OR reports unresolved — both disqualify, so
    # there is nothing left to check once the head is `parent`/`old`.
    #
    # A bare payload-field read is always fine. A bare owner-field read
    # is fine ONLY in an `ensures`/invariant phase (`:after`): by the
    # time this runs, the caller has already confirmed `owner_fields.
    # subset?(known_writes)`, so `head` is unconditionally already in
    # `known_writes` — the live Analyzer's own `!known_writes.include?
    # (name)` disjunct is therefore always false here, leaving `phase ==
    # :before` (a GIVEN, evaluated BEFORE the mutation that — even on
    # THIS SAME command — sets the field) as the one real disqualifying
    # condition. Neither payload nor owner names the live Analyzer's own
    # `unresolved` case — disqualifying, same as `parent`/`old`.
    def creation_path_state_independent?(path, phase, payload_fields, owner_fields)
      head, = path.split(".", 2)

      case head
      when "parent", "old"
        false
      else
        return true if payload_fields.include?(head)
        return false unless owner_fields.include?(head)

        phase != :before
      end
    end
  end
end
