module Hecks
  module SME
    module DiscoveryProjection
      # Reads the statement of an accepted discovery Point as the bluebook line it names.
      #
      # A deliberate step from ADR 0194's "a discovery Point is a line of bluebook text": a
      # statement in the participants' words becomes code only in this grammar, and is otherwise
      # a cited comment, never a guess (ADR 0088), as a rule and a transition always are:
      #
      # - a **thing** is one word, its name: `Order`;
      # - an **action** is the thing, the command and the event it emits: `Order: Place -> Placed`;
      # - a **field** is the thing and a lowercase attribute name: `Order: total`.
      module Statement
        # One word: letters and digits, starting with a letter.
        WORD = "[A-Za-z][A-Za-z0-9]*".freeze
        THING  = /\A\s*(#{WORD})\s*\z/
        ACTION = /\A\s*(#{WORD})\s*:\s*(#{WORD})\s*->\s*(#{WORD})\s*\z/
        FIELD  = /\A\s*(#{WORD})\s*:\s*([a-z][a-z0-9_]*)\s*\z/
        # The attribute every staged aggregate is identified by, so a field cannot take its name.
        IDENTITY = "ref".freeze

        module_function

        # @param statement [String] a thing Point's statement
        # @return [String, nil] the aggregate name, or nil when the statement is not one word
        def thing(statement)
          match = THING.match(statement.to_s)
          match && capital(match[1])
        end

        # @param statement [String] an action Point's statement
        # @return [Array(String, String, String), nil] the thing, command and event, or nil
        def action(statement)
          match = ACTION.match(statement.to_s)
          match&.captures&.map { |word| capital(word) }
        end

        # @param statement [String] a field Point's statement
        # @return [Array(String, String), nil] the thing and the attribute name, or nil
        def field(statement)
          match = FIELD.match(statement.to_s)
          return unless match && match[2] != IDENTITY

          [capital(match[1]), match[2]]
        end

        # @api private
        def capital(word) = word[0].upcase + word[1..]
      end
    end
  end
end
