require "json"
require "strscan"

module Hecks
  module Bluebook
    module TranslationExpression
      # Reads the text of an expression into its tree, refusing anything outside the language.
      class Parser
        NAME   = /[a-z_][a-z0-9_]*(?:\.[a-z_][a-z0-9_]*)*/
        STRING = /"(?:[^"\\]|\\.)*"/

        # @param text [String] the expression's source text
        def initialize(text)
          @text = text.to_s
          @scan = StringScanner.new(@text)
        end

        # @return [Array] the expression tree
        # @raise [TranslationExpression::Refused] if the text is not a well-formed expression
        def call
          tree = expression
          skip
          refuse("unexpected #{@scan.rest[0, 12].inspect} after the expression") unless @scan.eos?
          tree
        end

        private

        def expression
          skip
          return ["lit", string] if @scan.check(/"/)

          name = @scan.scan(NAME) || refuse("expected a field, a string or a function")
          return function(name) if @scan.check(/\s*\(/)

          name == "null" ? ["null"] : ["ref", name]
        end

        def function(name)
          refuse("#{name} is not a function (#{FUNCTIONS.keys.join(", ")})") unless FUNCTIONS.key?(name)
          punct("(")
          arguments = list { argument(name, _1) }
          punct(")")
          check_arguments(name, arguments)
          [name, *arguments]
        end

        def argument(name, index)
          skip
          return table if name == "lookup" && index == 1

          expression
        end

        def list
          items = []
          loop do
            items << yield(items.size)
            skip
            break unless @scan.skip(/,/)
          end
          items
        end

        def table
          punct("{")
          pairs = list { pair }
          punct("}")
          refuse("a lookup table repeats a key") unless pairs.map(&:first).uniq.size == pairs.size
          pairs.to_h
        end

        def pair
          skip
          key = string
          punct(":")
          skip
          [key, string]
        end

        def string
          token = @scan.scan(STRING) || refuse("expected a string")
          JSON.parse(token, quirks_mode: true)
        rescue JSON::ParserError
          refuse("#{token} is not a well-formed string")
        end

        def punct(mark)
          skip
          @scan.skip(Regexp.new(Regexp.escape(mark))) || refuse("expected #{mark.inspect}")
        end

        def skip = @scan.skip(/\s+/)

        def check_arguments(name, arguments)
          arity = FUNCTIONS.fetch(name)
          refuse("#{name} takes #{arity} expressions, not #{arguments.size}") if arity && arguments.size != arity
          refuse("concat takes two or more expressions") if arity.nil? && arguments.size < 2
          check_literals(name, arguments)
        end

        def check_literals(name, arguments)
          case name
          when "replace" then check_replace(arguments)
          when "lookup" then check_lookup(arguments)
          end
        end

        def check_replace(arguments)
          _target, from, to = arguments
          refuse("replace needs string literals for what to find and what to put") unless [from, to].all? { _1.first == "lit" }
          refuse("replace cannot look for an empty string") if from.last.empty?
        end

        def check_lookup(arguments)
          _key, table, fallback = arguments
          refuse("lookup needs a table of at least one pair") unless table.is_a?(Hash) && !table.empty?
          refuse("lookup needs a string literal or null as its fallback") unless %w[lit null].include?(fallback.first)
        end

        def refuse(why)
          raise Refused, "#{why} (in #{@text.inspect} at offset #{@scan.pos})"
        end
      end
    end
  end
end
