module Hecks
  module Bluebook
    module MetaValidator
      # The mode switches of judging: bootstrapping, deferring, disabled, shadow-parsing and the
      # forced fixpoint. `MetaValidator` extends this, so each reads and writes its own state.
      module Modes
        # Whether the language's own grammar is still loading raw, unjudged.
        # Judging it while it loads would recurse, so the bootstrap sets this
        # and the fixpoint clears it once every grammar file is merged.
        #
        # @return [Boolean]
        def bootstrapping? = @bootstrapping

        # Whether `call` is queuing chapters instead of judging them, while a
        # chapter's own files are still being merged (see `defer`).
        #
        # @return [Boolean]
        def deferring? = @deferring

        # Queues every chapter `call` sees while the block runs, instead of
        # judging them immediately (see `deferred_chapters`).
        #
        # @yield the caller's own load of every file in one chapter window
        # @return [Object] the block's own return value
        def defer
          previous   = @deferring
          @deferring = true
          yield
        ensure
          @deferring = previous
        end

        # The chapters queued while `defer`'s block ran, awaiting
        # `judge_deferred!`.
        #
        # @return [Array<String>] each deferred chapter's own `hecks_name`,
        #   queued during the current or most recent `defer` window
        def deferred_chapters = @deferred_chapters ||= []

        # Judges every chapter queued by `defer`, once each, then clears the
        # queue.
        #
        # @param registry [Runtime::Registry, nil] the registry to judge
        #   against; a no-op if `nil`
        # @return [void]
        # @raise [DSL::Malformed] if a chapter's own whole-chapter battery
        #   (`BluebookBuilder.validate_assembled!`) or the meta-domain itself
        #   (`call`) refuses it
        def judge_deferred!(registry)
          pending = deferred_chapters.uniq
          @deferred_chapters = []
          return unless registry

          pending.each { |name| judge_chapter!(registry, name) }
        end

        # Judges one deferred chapter once its own files are all merged.
        #
        # @param registry [Runtime::Registry] the registry holding the chapter
        # @param name [String] the chapter's `hecks_name`
        # @return [void]
        def judge_chapter!(registry, name)
          chapter = registry.bluebook(name)
          return unless chapter

          # Bare chapter-level givens must resolve before anything below
          # reads a `Given`'s fields. The `raise` block never runs — this
          # chapter's builder is always already open by the time `chapter` exists.
          builder = registry.bluebook_builder(name) { raise "internal: no open builder for #{name}" }
          builder.resolve_pending_chapter_givens!
          # Same, one level down: entity-scoped pending givens.
          builder.resolve_pending_chapter_entity_givens!

          # Whole-chapter checks (hops, projected fields, event shapes) were
          # skipped per file while deferring; `chapter` now holds every
          # file's declarations, so they run once here instead of per file.
          DSL::BluebookBuilder.validate_assembled!(chapter)
          registry.add_bluebook(call(chapter))
        end

        # Whether meta-domain judging is off (ignored while a fixpoint build
        # is forced).
        # Stack-restored, not a bare flag, so a disabled window can never
        # leak past its own scope.
        #
        # @return [Boolean]
        def disabled? = @disabled && !@forcing_fixpoint

        # Runs `block` with `disabled?` true, restoring it afterward — for a
        # growth spec that boots a scratch bluebook without validation overhead.
        #
        # @yield the caller's own boot, with `disabled?` true throughout
        # @return [Object] the block's own return value
        def while_disabled
          previous  = @disabled
          @disabled = true
          yield
        ensure
          @disabled = previous
        end

        # (ADR 0025) Whether frozen era text is currently being shadow-parsed
        # by `EraGuard`. Judging it again here would refuse history whenever a
        # spelling it used gets removed from the live grammar.
        #
        # @return [Boolean]
        def shadow_parsing? = @shadow_parsing

        # Wraps `block` with `shadow_parsing?` true, restoring it afterward.
        #
        # @yield the caller's own shadow-parse of one piece of frozen era text
        # @return [Object] the block's own return value
        def while_shadow_parsing
          previous        = @shadow_parsing
          @shadow_parsing = true
          yield
        ensure
          @shadow_parsing = previous
        end

        # Wraps `block` with `disabled?` forced false, restoring it afterward.
        # Only `grammar_registry`'s one-time fixpoint build uses this.
        #
        # @yield the one-time fixpoint build, with `disabled?` forced false
        #   throughout
        # @return [Object] the block's own return value
        def while_forcing_fixpoint
          previous          = @forcing_fixpoint
          @forcing_fixpoint = true
          yield
        ensure
          @forcing_fixpoint = previous
        end
      end
    end
  end
end
