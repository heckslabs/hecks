module Hecks
  module Ports
    module Persistence
      # One command applied to every row of a query, said without SQL (ADR 0129): the runtime
      # builds it from the bluebook, and a store that provides `set_transform` compiles it to one
      # statement in its own dialect. It names fields and parsed expressions, never columns.
      #
      # - `query`, `query_args`: the query's specification and arguments, as the store answers it
      # - `givens`: each given's parsed predicate, every one of which a row must meet
      # - `assignments`: each {SetStatement::Assignment} the command makes
      # - `transition`: the lifecycle cases in order, each `[from_states or nil, target]`; nil when
      #   the command moves no lifecycle
      # - `from_guard`: the lifecycle states the command is admissible from, or nil
      # - `arguments`: the command's arguments by name, each a plain scalar an expression reads
      SetStatement = Struct.new(:query, :query_args, :givens, :assignments, :transition, :from_guard, :arguments,
                                keyword_init: true)

      class SetStatement
        # One field a statement writes. `kind` says what `value` is:
        #
        # - `:constant`: the value every row takes, already shaped as the record holds it
        # - `:copy`: the name of the field whose value each row copies
        # - `:expression`: a parsed expression over the row and the arguments
        # - `:step`: the Integer added to the field (negative to take away)
        Assignment = Struct.new(:target, :kind, :value, keyword_init: true)
      end
    end
  end
end
