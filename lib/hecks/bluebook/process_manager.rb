require_relative "behaviour/process_manager"
require_relative "../ir"

module Hecks
  module Bluebook
    # `compensates` — a SECOND `DispatchSpec`, shape-identical to this
    # one, naming the command that undoes THIS dispatch specifically
    # (see `ProcessManagerBuilder::HandlerBuilder#dispatch_impl`'s own
    # comment). `nil` for a dispatch with nothing to undo (a pure
    # bookkeeping mark, or one whose own effect is superseded by a later
    # command rather than needing its own compensation). Never nested
    # further — a compensation is not itself compensable; no known
    # corpus need, and ADR 0025's own "a word earns its place by being
    # used" bar would refuse a second level speculatively.
    DispatchSpec = Struct.new(:command_name, :with_spec, :compensates, keyword_init: true) do
      # A Struct already answers to_h; including the mixin puts the
      # DECLARED emission ahead of Struct's own in the ancestry, which
      # is what makes the shape data rather than a method body.
      include Hecks::IR

      emits_ir(
        command_name: -> { command_name.to_s },
        with_spec:    -> { with_spec.map { |key, value| [key.to_s, Bluebook.render_value(value)] } },
        compensates:  one(:compensates)
      )
    end

    ProcessManagerHandler = Struct.new(:event_type, :from_state, :to_state,
                                       :dispatches, keyword_init: true) do
      include Hecks::IR

      emits_ir(
        event_type: -> { event_type.to_s },
        from_state: -> { from_state.to_s },
        to_state:   -> { to_state.to_s },
        dispatches: many(:dispatches)
      )
    end

    # The compensation half of a procedure, as its own thing.
    #
    # A PROCESS MANAGER coordinates: legs, states, an opinion about who goes
    # next. A SAGA undoes: what makes the world good again when a leg it
    # dispatched is refused. Two concepts, and the industry slurs them into one
    # word — so here they are two objects, and a procedure either has a saga or
    # does not.
    #
    # `undoes` is the ordered list of commands the compensation sends — a
    # STATIC PREVIEW, declaration order (`Behaviour::ProcessManager#saga`),
    # not one instance's own runtime history. Per-dispatch compensation
    # (`compensates`, on the step it compensates for) moved most of what
    # a saga undoes off this leg's own hand-written body and onto
    # whichever forward dispatch each one undoes — this reads every
    # declared `compensates` across the WHOLE saga first, then whatever
    # this leg's own hand-written body still lists, for compensation
    # that isn't expressible as "undo command X." WHICH of a declared
    # `compensates` actually fires for one instance, and in what order
    # (newest-first, completed-legs-only), is `SagaInterpreter`'s own
    # dynamic `completed_compensations` — a per-instance runtime fact
    # this declaration-only object could never hold.
    #
    # NAMING COLLISION, ONCE FLAGGED, NOW RESOLVED — `command`'s own
    # `corrects event, reverses: true` (docs/implemented/decisions/0036-
    # corrects-is-an-appended-fact-not-a-rewrite.md) already claimed
    # `reverses` for a different meaning: auto-deriving a command's OWN
    # corrective mutation from a past EVENT, not a saga's own
    # compensating leg from a past DISPATCH. This feature keeps
    # `reverses` reserved for `corrects` and uses `compensates` for
    # per-dispatch saga compensation instead — a deliberate choice, not
    # an accidental collision.
    Saga = Struct.new(:trigger, :from_state, :to_state, :compensations, keyword_init: true) do
      def undoes = compensations.map(&:command_name)

      def to_s = "#{trigger} → #{to_state} (#{undoes.join(', ')})"
    end

    class ProcessManager
      # The BLUEBOOK's name for this construct, asked the same way of a class
      # that has crossed over and of an IR object that has not. Collapses into
      # Construct when this one crosses.
      # The trigger of a compensating leg. Not an event name — no aggregate
      # announces that a leg the procedure dispatched was declined — so it lives
      # here beside the thing it triggers rather than in the runtime that
      # notices it. Declared in the language's Trigger vocabulary, which
      # spec/vocabulary_conformance_spec holds to this constant.
      REFUSED = Hecks::Vocabulary.fetch("Trigger").first

      include Hecks::IR
      include Behaviour::ProcessManager

      emits_ir(
        name:          :name,
        # M11 — `&.`, not `.`: a DSL-built process manager always carries
        # a real `correlates_by` (`ProcessManagerBuilder#build` refuses to
        # mint one without it), but the IR class itself defaults it to
        # `nil` and is what `Assembly::Build`'s `:identity` reader
        # (`value&.to_sym`) round-trips against. A bare `.to_s` mapped
        # that absent case to `""`, indistinguishable on the wire from a
        # real empty name and read back as the wrong, non-nil `:""`
        # instead of `nil` — the same nil-erasure S1 fixed for
        # `render_value`, one field over. `correlates_by` is always a
        # bare Symbol (`SagaInterpreter` hash-looks-up a payload by it),
        # never a `Literal`-encoded polymorphic value, so this stays a
        # local `&.` rather than routing through `Literal.render` — that
        # would wrap a real value in a leading `:` and break both the
        # `:identity` reader's plain `to_sym` and the pinned golden IR
        # fixtures' bare-string spelling (`"reference.value"`).
        correlates_by: -> { correlates_by&.to_s },
        starts_on:     :starts_on,
        ends_on:       :ends_on,
        states:        :states,
        handlers:      many(:handlers)
      )

      attr_reader :name, :correlates_by, :starts_on, :ends_on, :states, :handlers

      def initialize(name:, correlates_by: nil, starts_on: nil, ends_on: nil,
                     states: [], handlers: [])
        @name          = name.to_s
        @correlates_by = correlates_by
        @starts_on     = starts_on
        @ends_on       = ends_on
        @states        = states
        @handlers      = handlers
      end
    end
  end
end
