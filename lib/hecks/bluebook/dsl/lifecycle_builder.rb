require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Parses a `lifecycle :field, default: ... do transition ... end`
      # block into a `Lifecycle` — the field an aggregate or entity's own
      # state machine lives on, its starting value, and the `command =>
      # target_state` transition table (with an optional `from:` guard)
      # each `transition_impl` call adds a row to.
      class LifecycleBuilder
        GRAMMAR_CONTEXT = "Lifecycle".freeze

        include WordGate

        # @param field [Symbol, String] the attribute the state machine lives on, such as `:status`
        # @param default [String, Symbol] the state a new record starts in
        def initialize(field, default:)
          @field       = field
          @default     = default
          @transitions = []
        end

        # Records one transition row per command in `mapping`, all sharing its `from:` guard.
        #
        # Answers the `transition` word, which the grammar table routes here
        # through its `calls:` column — item #13's full metaprogrammed
        # dispatch (slice 4c). Bootstrap-reachable (syntax.bluebook's
        # own Keyword/Argument entities describe their `status`
        # lifecycle with it), so in `BOOTSTRAP_CALLS_FALLBACK`.
        #
        # @param mapping [Hash{String, Symbol => String, Symbol, Array<String>}] command name to
        #   target state, as in `"Purchase" => "sold"`; the optional `:from` key holds the
        #   state, or Array of states, the transition applies from, and nil or absent means any
        # @return [Hash] the command-to-target pairs just recorded, `:from` removed
        def transition_impl(mapping)
          mapping = mapping.dup
          from    = mapping.delete(:from)

          mapping.each do |command, target|
            @transitions << [
              command.to_s,
              StateTransition.new(target: target, from: from)
            ]
          end
        end

        # Assembles the declared transitions into a `Lifecycle`, refusing an ambiguous table.
        #
        # @return [Bluebook::Lifecycle] the state machine: its field, default and transitions
        # @raise [Bluebook::DSL::Malformed] if two transitions for one command could both apply
        #   from the same state (C5.3); skipped while shadow-parsing frozen era text
        def build
          refuse_ambiguity!
          Lifecycle.new(field: @field, default: @default, transitions: @transitions)
        end

        # Evaluates a `lifecycle` block against a fresh builder and returns what it built.
        #
        # @param field [Symbol, String] the attribute the state machine lives on
        # @param default [String, Symbol] the state a new record starts in
        # @yield the lifecycle body of `transition` rows, evaluated with the builder as `self`
        # @return [Bluebook::Lifecycle] the built state machine
        # @raise [Bluebook::DSL::Malformed] if two transitions for one command overlap, or the
        #   block uses a word the `Lifecycle` grammar does not admit
        def self.build(field, default:, &block)
          builder = new(field, default: default)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        # C5.3 (docs/semantics/bluebook-semantics.md) — two transitions for
        # one command whose `from:` sets overlap (or where either has no
        # `from:` at all) were silently first-wins; refused where the state
        # machine can be read whole. Two transitions for one command from
        # disjoint states are the legitimate shape (`match_transition`
        # picks by the current state) and stay. A `from:` naming a state
        # nothing declares is not refused here: it is a reachability
        # finding `bin/model_check` already reports (unreachable state,
        # dead transition), and a bluebook may declare it on purpose.
        def refuse_ambiguity!
          return if MetaValidator.shadow_parsing? # frozen era text is history

          @transitions.each_with_index do |(command, transition), index|
            earlier = @transitions[0...index].find do |other_command, other|
              other_command == command && overlap?(other, transition)
            end
            next unless earlier

            raise Malformed,
                  "lifecycle :#{@field} declares two transitions for #{command.inspect} from the same state " \
                  "(=> #{earlier.last.target.inspect} and => #{transition.target.inspect}) — which one fires " \
                  "would be declaration order; give them disjoint from: states"
          end
        end

        def overlap?(one, other)
          return true if one.from.nil? || other.from.nil?

          Array(one.from).map(&:to_s).intersect?(Array(other.from).map(&:to_s))
        end
      end
    end
  end
end
