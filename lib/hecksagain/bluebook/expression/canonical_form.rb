# CanonicalForm — the normalisation table, as data.
#
# One meaning, one text. Two spellings of a predicate would hash differently,
# diff as a change when nothing changed, and read as two distinct programs to
# anything that partially evaluates on the text.
#
# WHY A TABLE AND NOT A METHOD. The fold used to be a line of Ruby here and a
# line of Rust there, agreeing because two authors happened to write the same
# thing. They did not : this side anchored `.length` at a word boundary and the
# other replaced the bare substring, so `dims.length_cm` canonicalised to
# `dims.size_cm` in one runtime and stayed put in the other. Nothing caught it,
# because a rule stated in a COMMENT is a rule no diff can read.
#
# Borrowed from Hecks, which states a parse rule twice and both times the same
# way — a named PRIMITIVE plus its OPERANDS :
#
#   BlockGrammarEntry (keyword, parser)                  routing
#   FieldRule         (field, strategy, source_token)    extraction
#
# THE BOOTSTRAP IS DELIBERATE. `lib/hecksagain/grammar/expression.bluebook`
# declares this same table as `one_of` members and IS the canonical source ;
# RULES here must equal it, and a spec holds them to that. But extraction runs
# while a bluebook is still LOADING, so it cannot read a parsed bluebook to
# learn how to read a bluebook. Hecks names the same constraint in
# `BlockGrammar::canonical_bluebook` — "the parser of bluebook can't itself
# require a parsed bluebook to run" — and keeps its default table in code for
# exactly this reason. Regenerating this from the chapter is specializer work.
#
# AND THE TABLE IS IN THE CONTRACT. Both runtimes emit RULES into the IR they
# are diffed on, so a divergence between the two tables is a parity SPLIT rather
# than something found by probing. That is the part that makes them agree by
# construction instead of by care.
module Hecksagain
  module Bluebook
    module Expression
      module CanonicalForm
        # A rule is a named strategy plus its operands, applied in `position`
        # order. Order is declared, not left to the sequence each side happens
        # to write : collapsing whitespace before or after a fold can differ for
        # a rule whose boundary is a space.
        Rule = Struct.new(:strategy, :source_token, :replacement, :boundary, :position, keyword_init: true)

        # The strategies each target has LINKED. A rule may compose these ; it
        # may not invent one. Hecks draws the same line at
        # `BlockParser::from_name`, which answers None for an unknown name
        # because "the bluebook grammar can't reach functions that haven't been
        # linked into the binary".
        STRATEGIES = %w[collapse_whitespace replace].freeze

        RULES = [
          Rule.new(strategy: "collapse_whitespace", source_token: "", replacement: "", boundary: "none", position: 1),
          Rule.new(strategy: "replace", source_token: ".length", replacement: ".size", boundary: "word", position: 2)
        ].freeze

        module_function

        # The table as the parity contract carries it — ordered, all strings, so
        # the two runtimes' tables diff directly rather than through each
        # language's idea of a number.
        def table
          RULES.sort_by(&:position).map do |rule|
            {
              strategy:     rule.strategy,
              source_token: rule.source_token,
              replacement:  rule.replacement,
              boundary:     rule.boundary,
              position:     rule.position.to_s
            }
          end
        end

        def apply(source)
          RULES.sort_by(&:position).reduce(source.to_s) { |text, rule| step(text, rule) }.strip
        end

        def step(text, rule)
          case rule.strategy
          when "collapse_whitespace" then text.gsub(/\s+/, " ")
          when "replace"             then replace(text, rule)
          else
            # Unreachable through the declared table, and loud if it ever is.
            # Silently returning the text would be the fail-open the whole
            # chapter exists to refuse.
            raise ArgumentError, "#{rule.strategy.inspect} is not a linked normalisation strategy"
          end
        end

        # `boundary: "word"` means the token only folds when what follows is not
        # a word character — so `.length` folds and `.length_cm` does not. That
        # sentence is the one that was missing, and the one both sides now read
        # from the same row.
        def replace(text, rule)
          return text.gsub(rule.source_token, rule.replacement) if rule.boundary == "none"

          text.gsub(/#{Regexp.escape(rule.source_token)}(?![[:alnum:]_])/, rule.replacement)
        end
      end
    end
  end
end
