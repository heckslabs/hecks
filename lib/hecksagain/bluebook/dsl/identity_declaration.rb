module Hecksagain
  module Bluebook
    module DSL
      # `identified_by` — SHARED by AggregateBuilder and EntityBuilder
      # only (S9, ADR 0025 — "EntityBuilder's duplicate identified_by and
      # resolve_pending_identity! go"): a piece's own identity cannot
      # spell differently from its aggregate's, and until this slice it
      # was hand-duplicated onto both rather than shared.
      #
      # A SEPARATE MODULE from AttributeCollector on purpose — every
      # `attribute()`-taking builder (Command, Query, PortOperation,
      # ValueObject, ...) `include`s that one too, and none of THEM
      # declares an identity of its own ; folding `identified_by` in
      # there made it answer for six builders that never earned the
      # word (`syntax_conformance_spec.rb` catches exactly this — a
      # builder answering a method the grammar never grants it).
      #
      # Requires its includer to ALSO `include AttributeCollector`
      # (for `attributes`/`resolve_identity_field!`/`resolve_identity_
      # type!`, still declared there since every includer of THAT
      # module needs them) and to supply `identity_pool` (private) —
      # the value-object list a bare field's own type resolves
      # against: AggregateBuilder's own `@value_objects + closed_sets`,
      # or EntityBuilder's OWNER's, since a piece mints none of its own.
      module IdentityDeclaration
        # WHICH UNCHANGING FACTS SAY WHICH ONE THIS IS — a declared field,
        # never a minted one (ADR 0025, "Identity"). `identified_by :number`
        # points at an attribute already declared on its own line — the
        # type used to be spelled here too ONLY because that was the one
        # place minting it, and minting is gone.
        #
        # SEVERAL FIELDS, and the identity is their JOIN, in declaration
        # order — composite identity is `identified_by :branch_code,
        # :box_number`, not a block. A single-field value object auto-
        # unwraps to its own member (see `resolve_identity_field!`,
        # AttributeCollector's own); a bare scalar or a reference resolves
        # to its own name unchanged.
        def identified_by(*targets, as: nil, &path)
          return legacy_identified_by(targets.first, as: as, &path) if MetaValidator.shadow_parsing?

          raise Malformed,
                "#{@name}.identified_by no longer takes a block — write identified_by :field, " \
                "or identified_by :field_one, :field_two for a composite identity" if path
          raise Malformed, "#{@name}.identified_by names no field" if targets.empty?

          # A bareword constant (`PizzaName`) and a quoted field name
          # (`:name`) are BOTH plain Ruby Symbols/ScopedConstants by the
          # time they reach here — distinguished the same way the language
          # already reads everywhere else: a value object is PascalCase, a
          # field is snake_case.
          if targets.size == 1 && targets.first.to_s[0] =~ /[A-Z]/
            field = as || Naming.snake(targets.first)
            raise Malformed,
                  "#{@name}.identified_by no longer takes a value object — declare the attribute " \
                  "first (attribute :#{field}, #{targets.first}) and write identified_by :#{field}"
          end

          raise Malformed, "#{@name}.identified_by takes no as: — name the declared field itself" if as

          @identity_fields_pending = targets
        end

        private

        # RESOLVES whichever of the three `identified_by` shapes is
        # pending, against `identity_pool` — the includer's own private
        # hook. Called at BUILD time, not at `identified_by`'s own call
        # time — see `AttributeCollector#resolve_identity_field!`'s own
        # comment on why.
        def resolve_pending_identity!
          if @identity_type_pending
            type, as, insert_at = @identity_type_pending
            @identity_paths = resolve_identity_type!(type, as, insert_at, identity_pool, @name)
          elsif @identity_field_pending
            @identity_paths = resolve_identity_field!(@identity_field_pending, identity_pool, @name)
          elsif @identity_fields_pending
            @identity_paths = @identity_fields_pending.flat_map do |field|
              resolve_identity_field!(field, identity_pool, @name)
            end
          end
        end

        # LEGACY — the two removed spellings (a value object + as:, and the
        # multi-line block), kept alive ONLY for `EraGuard.shadow_parse`
        # (S0a, ADR 0025) to still make sense of frozen era text that used
        # them; unreachable outside `MetaValidator.shadow_parsing?`.
        def legacy_identified_by(target, as:, &path)
          if target
            raise Malformed, "#{@name}.identified_by takes a field name/value object or a block, not both" if path

            if target.to_s[0] =~ /[A-Z]/
              @identity_type_pending = [target, as, attributes.size]
            else
              raise Malformed,
                    "#{@name}.identified_by :#{target} takes no as: — as: only applies to identified_by ValueObject" if as

              @identity_field_pending = target
            end
            return
          end

          raise Malformed, "#{@name}.identified_by names no field" unless path

          paths = Ports::Extraction.canonical(path).to_s.split(" ").reject(&:empty?)
          raise Malformed, "#{@name}.identified_by names no field" if paths.empty?

          @identity_paths = paths
        end
      end
    end
  end
end
