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
        # There are three live forms, deliberately distinguishable at the
        # declaration site:
        #
        #   identified_by AccountNumber, as: :number # one identity concept
        #   identified_by do ... end                 # a bespoke concept
        #   identified_by :branch, :number           # an existing compound key
        #
        # One symbol is retired: it cannot say whether the author means a
        # value concept or a field-shaped database key. Frozen source still
        # reaches the old interpretation through `legacy_identified_by`.
        # RENAMED FROM `identified_by` — item #13's full metaprogrammed
        # dispatch (slice 4c), same shared-mixin shape `attribute_impl`
        # already proved in slice 3: ONE renamed method, both Aggregate
        # and Entity Keyword rows name it in `calls:`. Bootstrap-
        # reachable (every self-hosted aggregate/entity declares an
        # identity), so in BOOTSTRAP_CALLS_FALLBACK for both contexts.
        def identified_by_impl(*targets, as: nil, &definition)
          return legacy_identified_by(*targets, as: as, &definition) if MetaValidator.shadow_parsing?

          refuse_second_identity!

          if definition
            raise Malformed,
                  "#{@name}.identified_by cannot combine a value-object type with a block" unless targets.empty?

            type_name = identity_value_object_name
            value_object =
              begin
                ValueObjectBuilder.build(
                  type_name,
                  owner_value_objects: identity_pool,
                  &definition
                )
              rescue NameError => error
                # A REMOVED SPELLING MUST REFUSE LOUDLY, not degrade into a raw
                # Ruby error — the one contract `EraGuard.shadow_parse` leans
                # on to know a normal parse genuinely could not read this text
                # (only `Malformed` triggers its shadow-mode retry, era_guard.rb's
                # own comment). The OLD `identified_by { name.value }` — a block
                # whose text was NEVER CALLED, only extracted (legacy_
                # identified_by, below) — is exactly this shape: read under the
                # CURRENT grammar it is instead instance_eval'd as a value-object
                # DEFINITION, and a bare identifier like `name` inside it resolves
                # to nothing WordGate#method_missing recognizes, so Ruby itself
                # raises NameError. Left uncaught, that NameError skipped
                # shadow_parse's rescue entirely and reached callers as a raw
                # crash instead of the frozen-era fallback that exists for
                # precisely this text.
                raise Malformed,
                      "#{@name}.identified_by do ... end could not be read as a value-object " \
                      "definition: #{error.message}"
              end
            if value_object.attributes.empty?
              raise Malformed, "#{@name}.identified_by do declares no identity attributes"
            end

            install_identity_value_object!(value_object)
            @identity_type_pending = [value_object, as || :identity, attributes.size]
            return
          end

          raise Malformed, "#{@name}.identified_by names no identity" if targets.empty?

          if targets.one? && identity_type?(targets.first)
            @identity_type_pending = [targets.first, as, attributes.size]
            return
          end

          if targets.one?
            field = targets.first
            raise Malformed,
                  "#{@name}.identified_by takes no as: — name the declared field itself" if as
            # Transitional compatibility: the self-hosted language and live
            # corpus still contain this form. Keep it readable until their
            # exemplar-led migration is complete; the final lifecycle cutover
            # replaces this assignment with the targeted refusal.
            @identity_field_pending = field
            return
          end

          unless targets.all? { |target| !identity_type?(target) }
            raise Malformed,
                  "#{@name}.identified_by takes one value-object type or two or more attribute names, not both"
          end
          raise Malformed, "#{@name}.identified_by compound keys take no as:" if as

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

        def identity_type?(target) = target.to_s.match?(/\A[A-Z]/)

        def refuse_second_identity!
          # During the staged migration a transitional one-symbol declaration
          # may be replaced by the new declaration later in the same builder.
          # This keeps existing builder fixtures/source readable while their
          # exemplar is migrated. Once one-symbol identity is retired this
          # compatibility branch disappears with it.
          if @identity_field_pending && !@identity_type_pending && !@identity_fields_pending
            @identity_field_pending = nil
            return
          end

          return unless @identity_type_pending || @identity_field_pending || @identity_fields_pending ||
                        (@identity_paths && !@identity_paths.empty?)

          raise Malformed, "#{@name} declares identified_by more than once"
        end

        # LEGACY — the two removed spellings (a value object + as:, and the
        # multi-line block), kept alive ONLY for `EraGuard.shadow_parse`
        # (S0a, ADR 0025) to still make sense of frozen era text that used
        # them; unreachable outside `MetaValidator.shadow_parsing?`.
        def legacy_identified_by(*targets, as:, &path)
          target = targets.first
          if target
            raise Malformed, "#{@name}.identified_by takes a field name/value object or a block, not both" if path

            if targets.size > 1
              raise Malformed, "#{@name}.identified_by takes no as: with a compound key" if as

              @identity_fields_pending = targets
              return
            end

            if identity_type?(target)
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
