require_relative "word_gate"
require_relative "bluebook_builder/validation"
module Hecks
  module Bluebook
    module DSL
      # The `Hecks.bluebook "Name" do ... end` receiver, collecting every aggregate,
      # read model, policy and process manager a chapter declares.
      class BluebookBuilder
        GRAMMAR_CONTEXT = "Bluebook".freeze

        include WordGate
        extend Validation

        attr_reader :classification

        # @param name [String] the chapter's declared name
        # @param version [String, nil] the chapter's pinned version, or nil for unversioned
        def initialize(name, version: nil)
          @name       = name
          @version    = version
          @aggregates       = []
          @read_models      = []
          @policies         = []
          @process_managers = []
          # The root of the chapter-wide given pool, one level wider than
          # `AggregateBuilder`'s `@entity_named_givens` (S10). See `#given` for
          # what this closes.
          @chapter_named_givens = {}
          # Every bare chapter-given reference left unresolved so far, threaded into
          # every aggregate like `@chapter_named_givens`. See
          # `AggregateBuilder#pending_chapter_given` for what queues here.
          @chapter_pending_givens = []
          # One level wider still — the chapter-wide, entity-scoped pool, the piece
          # analogue of `@chapter_named_givens`. See `EntityBuilder#given_impl` and
          # docs/implemented/resolution-rules/chapter-entity-given.md for the algorithm.
          @chapter_entity_named_givens   = {}
          @chapter_entity_pending_givens = []
        end

        # Chapter metadata belongs to the composed builder, not whichever file sorts
        # first; two different versions for one chapter is a real contradiction.
        def adopt_version(version)
          return if version.nil?
          if @version && @version.to_s != version.to_s
            raise Malformed,
                  "#{@name} declares both version #{@version.inspect} and #{version.inspect}"
          end

          @version = version
        end
        private :adopt_version

        # Records the chapter's vision statement.
        #
        # @param value [String] the vision text, as given to `vision "..."`
        # @return [void]
        def vision(value)
          @vision = value
        end

        # Records the chapter's earlier name, so the storage layer recognizes its history
        # under it instead of minting a new lineage — a chapter's identity can change.
        #
        # @param value [String, Symbol] the chapter's earlier name
        # @return [String] `value`, stringified, as stored
        def formerly_known_as(value) = @formerly_known_as = value.to_s

        # Names a core grammar context this chapter's sub-language extends (ADR 0026).
        # Variadic and accumulates across calls, like `identified_by`/`group_by`.
        #
        # Reached through `calls: "attaches_to_impl"`, not bootstrap-reachable — only
        # sub-language chapters like Paging call it, never a core chapter.
        #
        # @param contexts [Array<String>] one or more core grammar context names, such as
        #   `"Query"`/`"ReadModel"`
        # @return [Array<String>] every context named so far, this call's included
        def attaches_to_impl(*contexts) = (@attaches_to ||= []).concat(contexts.map(&:to_s))

        # Records a capability this chapter answers for other domains, one row per key —
        # checked once the chapter is whole, since verbs may be declared later in the file.
        #
        # @param capability [String] the capability's own name, such as `"authorization"`
        # @param verbs [Hash{Symbol => String}] one command/query reference per capability
        #   key, e.g. `grant: "RoleAssignment.Assign"`
        # @return [Array<Bluebook::Chapter::Provision>] every provision row declared so far,
        #   this capability's included
        # @raise [Bluebook::DSL::Malformed] if `verbs` is empty
        def provides_impl(capability, **verbs)
          if verbs.empty?
            raise Malformed, "#{@name}'s provides #{capability.inspect} names no verb — say which of this " \
                             "chapter's commands and queries answer it"
          end

          rows = verbs.map { |key, verb| Chapter::Provision.new(capability: capability.to_s, key: key.to_s, verb: verb.to_s) }
          (@provides ||= []).concat(rows)
        end

        # Classifies this chapter as core to the framework, rather than a domain built on it.
        #
        # @return [Symbol] `:core`
        def core       = @classification = :core

        # Classifies this chapter as a supporting piece of the framework, rather than a domain
        # built on it.
        #
        # @return [Symbol] `:supporting`
        def supporting = @classification = :supporting

        # Classifies this chapter as generic infrastructure, rather than a domain built on it.
        #
        # @return [Symbol] `:generic`
        def generic    = @classification = :generic

        # Declares an aggregate belonging to this chapter. `@chapter_named_givens` is
        # threaded into it — see `AggregateBuilder#given` for the sharing this enables.
        #
        # Bootstrap-reachable (every core chapter's top-level shape uses it), so also
        # named in `GenericDispatch::BOOTSTRAP_CALLS_FALLBACK`.
        #
        # @param name [String] the aggregate's own name
        # @yield the aggregate body, evaluated against a new `AggregateBuilder`; may be omitted
        # @return [Array<Bluebook::Aggregate>] every aggregate declared so far, this one last
        # @raise [Bluebook::DSL::Malformed] if the aggregate's own body fails any check
        #   `AggregateBuilder#build` raises
        def aggregate_impl(name, &)
          @aggregates << AggregateBuilder.build(name, chapter_named_givens:          @chapter_named_givens,
                                                      chapter_pending_givens:        @chapter_pending_givens,
                                                      chapter_entity_named_givens:   @chapter_entity_named_givens,
                                                      chapter_entity_pending_givens: @chapter_entity_pending_givens, &)
        end

        # Declares a read model belonging to this chapter.
        #
        # @param name [String] the read model's own name
        # @yield the read model body, evaluated against a new `ReadModelBuilder`
        # @return [Array<Bluebook::ReadModel>] every read model declared so far, this one last
        # @raise [Bluebook::DSL::Malformed] if the body fails any check `ReadModelBuilder#build`
        #   raises
        def read_model(name, &)
          # A read model gathers heads from several aggregates, so no single head
          # declares it — the chapter does. Its owner is stamped in `build`, where
          # the chapter namespace exists.
          @read_models << ReadModelBuilder.build(name, &)
        end

        # Answered only under shadow-parsing, so frozen era text spelled `report` keeps
        # booting; live source refuses it and names `read_model` as the replacement.
        #
        # @param name [String] the read model's own name
        # @yield the read model body, evaluated against a new `ReadModelBuilder`
        # @return [Array<Bluebook::ReadModel>] every read model declared so far, this one last,
        #   under shadow-parsing
        # @raise [Bluebook::DSL::Malformed] always, outside shadow-parsing
        def report(name, &)
          return read_model(name, &) if MetaValidator.shadow_parsing?

          raise Malformed, "report is gone — read_model is the word now"
        end

        # Declares a policy belonging to this chapter.
        #
        # @param name [String] the policy's own name
        # @yield the policy body, evaluated against a new `PolicyBuilder`
        # @return [Array<Bluebook::Policy>] every chapter-level policy declared so far,
        #   this one last
        def policy(name, &)
          @policies << PolicyBuilder.build(name, &)
        end

        # Declares a process manager (saga) belonging to this chapter.
        #
        # @param name [String] the process manager's own name
        # @yield the process manager body, evaluated against a new `ProcessManagerBuilder`
        # @return [Array<Bluebook::ProcessManager>] every process manager declared so far,
        #   this one last
        def process_manager(name, &)
          @process_managers << ProcessManagerBuilder.build(name, &)
        end

        # Assembles this builder's accumulated declarations into a judged `Chapter`.
        #
        # @return [Bluebook::Chapter] the built chapter, judged by the language when not
        #   deferring across a multi-file chapter
        # @raise [Bluebook::DSL::Malformed] if a chapter-wide given reference cannot be
        #   resolved, if cross-construct validation fails, or if the language's own
        #   whole-document judgment refuses the chapter
        # @raise [Bluebook::DSL::ProcessManagerBuilder::InvalidProcessManager] if a process
        #   manager's own structural check fails
        def build
          # The chapter is the top of the construct chain — its constructor stamps every
          # aggregate and read model with itself as owner, so `hecks_fqn` resolves by
          # walking up to it.
          bluebook = Bluebook::Chapter.new(name: @name, version: @version, vision: @vision,
                                           aggregates: @aggregates,
                                           read_models: @read_models,
                                           policies: @aggregates.flat_map(&:policies) + @policies,
                                           process_managers: @process_managers,
                                           classification: @classification,
                                           formerly_known_as: @formerly_known_as,
                                           attaches_to: @attaches_to || [],
                                           provides: @provides || [])

          # A bare chapter-given may still be pending if a file that would resolve it
          # hasn't loaded yet; deferred to `MetaValidator.judge_deferred!`, before
          # `validate_assembled!`, so nothing downstream reads an unresolved placeholder.
          resolve_pending_chapter_givens! unless MetaValidator.deferring?
          resolve_pending_chapter_entity_givens! unless MetaValidator.deferring?

          # A chapter may span several files; a hop/projection/event can name a construct
          # not yet loaded, so this is skipped while `MetaValidator.defer` loads the
          # chapter's files and run once by `judge_deferred!` against the whole chapter.
          self.class.validate_assembled!(bluebook) unless MetaValidator.deferring?

          # The language judges the bluebook last, so the meta-domain sees a fully built
          # IR — whole-document rules need every declaration present, so they can't be
          # per-declaration givens.
          MetaValidator.call(bluebook)
        end

        # The other half of a chapter-wide `given` reference — resolves every reference
        # `AggregateBuilder#pending_chapter_given` deferred, once the chapter's files are loaded.
        #
        # Mutates each placeholder `Given` in place, since it's already embedded by Ruby
        # object reference in the referencing preconditions and commands.
        #
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if a pending reference's own `description` names no
        #   precondition any aggregate in this chapter declares, is ambiguous across several
        #   aggregates with no `declared_by:` to disambiguate, or `declared_by:` names an
        #   aggregate that does not declare it
        def resolve_pending_chapter_givens!
          @chapter_pending_givens.each do |entry|
            resolved = resolve_pending_chapter_given(entry)
            entry[:placeholder].description = resolved.description
            entry[:placeholder].canonical   = resolved.canonical
            entry[:placeholder].predicate   = resolved.predicate
            entry[:placeholder].ast         = resolved.ast
          end
          @chapter_pending_givens.clear
        end

        def resolve_pending_chapter_given(entry)
          description = entry[:description]
          candidates  = RuleReference.resolve_owner_keyed(@chapter_named_givens, description)

          if entry[:declared_by]
            candidates[entry[:declared_by]] ||
              raise(Malformed,
                    "#{entry[:aggregate]}'s given #{description.inspect} names no precondition " \
                    "#{entry[:declared_by]} declares in this chapter — #{entry[:declared_by]} " \
                    "either hasn't declared #{description.inspect}, or declared_by: named the " \
                    "wrong aggregate")
          elsif candidates.size == 1
            candidates.values.first
          elsif candidates.empty?
            raise(Malformed,
                  "#{entry[:aggregate]}'s given #{description.inspect} names no precondition " \
                  "any aggregate in this chapter ever declares — declare it once with a block " \
                  "(some aggregate's own given(#{description.inspect}) { ... })")
          else
            raise(Malformed,
                  "#{entry[:aggregate]}'s given #{description.inspect} is ambiguous in this " \
                  "chapter — #{candidates.keys.join(', ')} each declare a DIFFERENT predicate " \
                  "under this same description; name which one with declared_by: (e.g. " \
                  "given(#{description.inspect}, declared_by: #{candidates.keys.first}))")
          end
        end
        private :resolve_pending_chapter_given

        # The entity-scoped analogue of `#resolve_pending_chapter_givens!`, resolved
        # against `@chapter_entity_named_givens` instead.
        #
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if a pending reference's own `description` names no
        #   precondition any piece in this chapter declares, is ambiguous across several pieces
        #   with no `declared_by:` to disambiguate, or `declared_by:` names a piece that does
        #   not declare it
        def resolve_pending_chapter_entity_givens!
          @chapter_entity_pending_givens.each do |entry|
            resolved = resolve_pending_chapter_entity_given(entry)
            entry[:placeholder].description = resolved.description
            entry[:placeholder].canonical   = resolved.canonical
            entry[:placeholder].predicate   = resolved.predicate
            entry[:placeholder].ast         = resolved.ast
          end
          @chapter_entity_pending_givens.clear
        end

        def resolve_pending_chapter_entity_given(entry)
          description = entry[:description]
          candidates  = RuleReference.resolve_owner_keyed(@chapter_entity_named_givens, description)

          if entry[:declared_by]
            candidates[entry[:declared_by]] ||
              raise(Malformed,
                    "#{entry[:entity]}'s given #{description.inspect} names no precondition " \
                    "#{entry[:declared_by]} declares in this chapter — #{entry[:declared_by]} " \
                    "either hasn't declared #{description.inspect}, or declared_by: named the " \
                    "wrong piece")
          elsif candidates.size == 1
            candidates.values.first
          elsif candidates.empty?
            raise(Malformed,
                  "#{entry[:entity]}'s given #{description.inspect} names no precondition " \
                  "any piece in this chapter ever declares — declare it once with a block " \
                  "(some piece's own given(#{description.inspect}) { ... })")
          else
            raise(Malformed,
                  "#{entry[:entity]}'s given #{description.inspect} is ambiguous across the " \
                  "chapter's own pieces — #{candidates.keys.join(', ')} each declare a DIFFERENT " \
                  "predicate under this same description; name which one with declared_by: (e.g. " \
                  "given(#{description.inspect}, declared_by: #{candidates.keys.first.inspect}))")
          end
        end
        private :resolve_pending_chapter_entity_given

        # Builds a `Chapter` from a `Hecks.bluebook "Name" do ... end` block, reusing one open
        # builder per chapter name so several files accumulate into it rather than replacing it.
        #
        # @param name [String] the chapter's declared name
        # @param version [String, nil] the chapter's pinned version, or nil for unversioned
        # @yield the chapter body; a bare constant resolves to a `ConstShim::ScopedConstant`
        # @return [Bluebook::Chapter] the built, judged chapter
        # @raise [Bluebook::DSL::Malformed] if `version` conflicts with an already-adopted
        #   version, or the built chapter fails validation
        # @raise [Bluebook::DSL::ProcessManagerBuilder::InvalidProcessManager] if a process
        #   manager's structural check fails
        def self.build(name, version: nil, &block)
          registry = Hecks.current_registry
          # Two frames up: this method's caller is `Hecks.bluebook` (hecks.rb), whose
          # caller is the real `.bluebook` file's own top-level call site.
          caller_location = caller_locations(2, 1)&.first
          registry&.record_bluebook_source(name, caller_location&.path)
          builder = registry ? registry.bluebook_builder(name) { new(name, version: version) } : new(name, version: version)
          builder.__send__(:adopt_version, version)
          # A bare constant like `PizzaName` is a name, not a Ruby reference —
          # `const_missing` hands over a `ConstShim::ScopedConstant`. A Module rather
          # than a Symbol is what lets `Account::Debit` answer its own `::`.
          resolver = ->(const) { ConstShim::ScopedConstant.for(const) }
          ConstShim.with(resolver) { builder.instance_eval(&block) } if block
          builder.build
        end
      end
    end
  end
end
