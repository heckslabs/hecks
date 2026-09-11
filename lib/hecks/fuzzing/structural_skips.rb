module Hecks
  module Fuzzing
    # WHAT A "NOT GENERATED FOR THIS DOMAIN" REFUSAL IS HIDING, PER VERB.
    #
    # `RustConformanceHelpers#structurally_refused_verbs` drops every named
    # query/read model the compiled Rust kernel answers "is not generated
    # for this domain" from BOTH sides of the differential comparison —
    # correct (the refusal is codegen's own honest "I cannot execute this
    # construct at all", `rust/project/queries.rb`'s and `read_models.rb`'s
    # documented boundary), but SILENT: a sweep over a domain whose every
    # `offset`/`cursor`/`group_by`/`count`/`median` ask was dropped reads
    # as "agreed across all steps" with nothing on the record saying how
    # much of the domain was never compared at all. Worse, the drop keys
    # on Rust's wording alone, so a codegen regression that started
    # refusing a plain wheres-only query the same way would ALSO vanish
    # into "agreed" — the exact quiet divergence the practice hunts.
    #
    # This module attributes each dropped verb to the constructs its OWN
    # Ruby declaration carries, in the vocabulary `queries.rb`/
    # `read_models.rb`'s skip reasons already use, so `bin/qa_sweep` can
    # log one Check per sweep saying exactly which verbs were skipped and
    # WHY — and mark it Surprised whenever a skipped verb declares nothing
    # the dial `QualityControlDials::STRUCTURAL_REFUSAL_BOUNDARY` admits as
    # a reason to skip (a wheres-only query on plain fields, a rooted
    # read model with nothing but heads, a verb Ruby doesn't even declare).
    #
    # COARSER THAN CODEGEN'S OWN PREDICATE, ON PURPOSE. `query_where_skip_
    # reason` decides per where clause from the field's resolved KIND
    # (number/string/multi-member value object) — reproducing that here
    # would be a second copy of codegen's typing rules, drifting on its
    # own. Instead a literal-valued where is reported as `where_literal`,
    # a family the dial admits, and only shapes with NO admitted family at
    # all surprise. That trades some sensitivity for zero false surprises
    # on today's corpus; the Check's observation still names every skipped
    # verb with its constructs, so a human reading the sweep sees what was
    # accepted and can narrow the dial when codegen grows.
    module StructuralSkips
      module_function

      # `Query#to_h`/`ReadModel#to_h` keys that, when present and
      # non-empty, are constructs codegen documents as (conditionally or
      # wholly) ungenerated — the same names as the dial's own vocabulary.
      QUERY_OPTION_KEYS      = %i[order_by limit offset cursor consistency freshness authorization inspection
                                  index_hints scope_to].freeze
      READ_MODEL_OPTION_KEYS = %i[wheres order_by limit offset cursor consistency freshness authorization inspection
                                  index_hints group_by count median_field].freeze

      # One entry per skipped verb: `{ verb:, constructs: [...] }`, the
      # constructs sorted so the printed observation is stable across
      # seeds and runs.
      def attribute(bluebooks, verbs)
        verbs.sort.map { |verb| { verb: verb, constructs: constructs_of(bluebooks, verb) } }
      end

      # Every skipped verb whose constructs are NOT all inside `boundary`
      # — including a verb with no constructs at all (nothing explains the
      # skip) and a verb Ruby never declared (`unknown`).
      def outside_boundary(attributed, boundary)
        admitted = boundary.map(&:to_s)
        attributed.select { |entry| entry[:constructs].empty? || (entry[:constructs] - admitted).any? }
      end

      def constructs_of(bluebooks, verb)
        if verb.include?("::")
          query = find_query(bluebooks, verb)
          return %w[unknown] unless query

          query_constructs(query)
        else
          model = find_read_model(bluebooks, verb)
          return %w[unknown] unless model

          read_model_constructs(model)
        end
      end

      # "Domain::Aggregate.Query" or "Domain::Aggregate.Entity.Query" — the
      # two named-query spellings `Fuzzing::SequenceGenerator`'s catalog
      # generates (entity queries stay one hop deep there).
      def find_query(bluebooks, verb)
        domain, rest = verb.split("::", 2)
        aggregate_name, *path = rest.to_s.split(".")
        aggregate = bluebooks[domain]&.aggregate(aggregate_name)
        return nil unless aggregate && path.any?

        owner = aggregate
        path[0...-1].each do |entity_name|
          owner = owner.entities.find { |entity| entity.hecks_name == entity_name }
          return nil unless owner
        end
        owner.query(path.last)
      end

      # "Domain.report_name" — the bare read-model form `Dispatcher#query`
      # routes by the absence of "::".
      def find_read_model(bluebooks, verb)
        domain, name = verb.split(".", 2)
        bluebooks[domain]&.read_models&.find { |model| model.query_name.to_s == name.to_s }
      end

      def query_constructs(query)
        spec = query.to_h
        constructs = QUERY_OPTION_KEYS.select { |key| present?(spec[key]) }.map(&:to_s)
        constructs << "null_semantics" if spec[:null_semantics] && spec[:null_semantics] != { mode: "native" }
        constructs << "no_wheres" if Array(spec[:wheres]).empty?
        constructs.concat(where_constructs(Array(spec[:wheres])))
        constructs.uniq.sort
      end

      def read_model_constructs(model)
        spec = model.to_h
        constructs = READ_MODEL_OPTION_KEYS.select { |key| present?(spec[key]) }.map(&:to_s)
        constructs << "null_semantics" if spec[:null_semantics] && spec[:null_semantics] != { mode: "native" }
        constructs << "rootless" if model.reference_target.nil?
        constructs.concat(where_constructs(Array(spec[:wheres])))
        constructs.uniq.sort
      end

      # The where-clause families `query_where_skip_reason` refuses by:
      # a `/` hop through a reference, a `.` walk into a nested field
      # (an entity-scoped or value-object path codegen may not resolve),
      # `none_in_state` (admitted by the vocabulary, deliberately not
      # generated), and any literal (non-Symbol) value, whose true wire
      # type codegen may not recover from the IR.
      def where_constructs(wheres)
        wheres.flat_map do |where|
          field = where[:field].to_s
          value = where[:value].to_s
          families = []
          families << "reference_hop_where" if field.include?("/")
          families << "where_nested_field" if field.include?(".")
          families << "where_none_in_state" if where[:op].to_s == "none_in_state"
          families << "where_literal" unless value.start_with?(":")
          families
        end
      end

      def present?(value)
        return false if value.nil? || value == false
        return value.any? if value.respond_to?(:empty?)

        true
      end
    end
  end
end
