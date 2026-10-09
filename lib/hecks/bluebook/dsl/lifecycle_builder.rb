require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Parses a `lifecycle :field, default: ... do transition ... end` block into a `Lifecycle`.
      class LifecycleBuilder
        GRAMMAR_CONTEXT = "Lifecycle".freeze

        include WordGate

        # @param field [Symbol, String] the attribute the state machine lives on, such as `:status`
        # @param default [String, Symbol] the state a new record starts in
        def initialize(field, default:)
          @field       = field
          @default     = default
          @transitions = []
          @marks       = {}
        end

        # Names a meaning and the states that carry it, such as
        # `mark :holds_seat, "pending", "succeeded"`.
        #
        # Listed in `BOOTSTRAP_CALLS_FALLBACK` because syntax.bluebook uses it during boot.
        #
        # @param name [Symbol, String] a lowercase word (`holds_seat`)
        # @param states [Array<String, Symbol>] one or more states, each named once
        # @return [Array<String>] the states just recorded
        # @raise [Bluebook::DSL::Malformed] for a name that is not a lowercase word, a name
        #   declared twice, no states, or a state named twice in one mark
        def mark_impl(name, *states)
          mark = name.to_s
          unless mark.match?(/\A[a-z][a-z0-9_]*\z/)
            raise Malformed, "lifecycle :#{@field} mark #{name.inspect} is not a lowercase word (such as :holds_seat)"
          end
          raise Malformed, "lifecycle :#{@field} declares mark :#{mark} twice" if @marks.key?(mark)
          raise Malformed, "lifecycle :#{@field} mark :#{mark} names no states" if states.empty?

          names = states.map(&:to_s)
          twice = names.find { |state| names.count(state) > 1 }
          raise Malformed, "lifecycle :#{@field} mark :#{mark} names state #{twice.inspect} twice" if twice

          @marks[mark] = names
        end

        # Records one transition row per command in `mapping`, all sharing its `from:` guard.
        #
        # Listed in `BOOTSTRAP_CALLS_FALLBACK` because syntax.bluebook uses it during boot.
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
        #   from the same state (C5.3; skipped while shadow-parsing frozen era text), or a mark
        #   names a state the lifecycle does not have
        def build
          refuse_ambiguity!
          refuse_unknown_mark_states!
          Lifecycle.new(field: @field, default: @default, transitions: @transitions, marks: @marks)
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

        # A mark may name only the default or a transition target: anything else is a typo that
        # would silently mark nothing. (A `from:` state is not enough; it is not reachable.)
        def refuse_unknown_mark_states!
          known = ([@default] + @transitions.map { |(_command, transition)| transition.target }).map(&:to_s)

          @marks.each do |mark, states|
            unknown = states - known
            next if unknown.empty?

            raise Malformed,
                  "lifecycle :#{@field} mark :#{mark} names #{unknown.map(&:inspect).join(", ")}, which " \
                  "is not a state of the lifecycle (states: #{known.uniq.join(", ")})"
          end
        end

        # C5.3 (docs/semantics/bluebook-semantics.md): overlapping `from:` sets for one command
        # are refused. Disjoint sets are legitimate. An undeclared `from:` state is left to
        # `hecks model_check`.
        def refuse_ambiguity!
          return if MetaValidator.shadow_parsing? # frozen era text is exempt

          @transitions.each_with_index do |(command, transition), index|
            earlier = earlier_overlap(command, transition, index)
            next unless earlier

            raise Malformed,
                  "lifecycle :#{@field} declares two transitions for #{command.inspect} from the same state " \
                  "(=> #{earlier.last.target.inspect} and => #{transition.target.inspect}) — which one fires " \
                  "would be declaration order; give them disjoint from: states"
          end
        end

        def earlier_overlap(command, transition, index)
          @transitions[0...index].find do |other_command, other|
            other_command == command && overlap?(other, transition)
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
