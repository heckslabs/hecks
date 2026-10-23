require_relative "../bluebook/named_pattern"

module Hecks
  module Forms
    module FieldShape
      # Says in plain words what a field accepts, read only from what the bluebook declares:
      # the attribute's type, its named `matches:` pattern, and the invariants of the value
      # object it sits in. An invariant this module cannot read is quoted by its own
      # description rather than guessed at.
      module RuleWords
        # Words for each `Bluebook::NamedPattern` name; a raw regex has none and is not shown.
        PATTERN_WORDS = {
          present:       "Must not be blank.",
          not_empty:     "Must not be empty.",
          no_whitespace: "No spaces.",
          snake_name:    "Lowercase letters, digits and underscores, starting with a letter.",
          git_sha:       "A commit id: 7 to 40 hexadecimal characters.",
          digits:        "Digits only."
        }.freeze

        # The noun a numeric type reads as, for "A whole number above zero."
        NUMBER_NOUNS = { "Integer" => "A whole number", "Float" => "A number" }.freeze

        # One comparison of the attribute against a literal number, as its canonical source
        # spells it: `value > 0`, `cents >= 0`.
        COMPARISON = /\A(?<name>\w+) (?<op>>=|<=|>|<) (?<bound>-?\d+(?:\.\d+)?)\z/

        # How each comparison reads after the noun: "above 5", "10 or less".
        BOUND_WORDS = { ">" => "above %s", ">=" => "%s or more", "<" => "below %s", "<=" => "%s or less" }.freeze

        module_function

        # Describes what `attribute` accepts, or nil when nothing declared can be said in words.
        #
        # @param attribute [Bluebook::Attribute] the scalar attribute the field asks for
        # @param invariants [Array<Bluebook::Invariant>] the rules of the value object that
        #   wraps `attribute`; empty for a bare attribute
        # @return [String, nil] one or more sentences, such as "A whole number above zero."
        def describe(attribute, invariants = [])
          readable, quoted = invariants.partition { |rule| reading(attribute, rule) }
          sentences = [type_sentence(attribute, readable), pattern_sentence(attribute, readable)]
          sentences += quoted.map { |rule| "Rule: #{rule.description}." }
          text = sentences.compact.uniq.join(" ")
          text.empty? ? nil : text
        end

        # @return [String, nil] the numeric noun with every readable bound, such as
        #   "A whole number above zero." or "A whole number, zero or more."; nil for a
        #   non-numeric attribute
        def type_sentence(attribute, readable)
          noun = NUMBER_NOUNS[attribute.type.to_s]
          return nil unless noun

          bounds = Naming.to_sentence_list(readable.map { |rule| reading(attribute, rule) }.grep_v(:not_blank))
          return "#{noun}." if bounds.empty?

          "#{noun}#{bounds.start_with?("above", "below") ? " " : ", "}#{bounds}."
        end

        # @return [String, nil] "Must not be blank." when the named pattern or a readable
        #   invariant says so, or the named pattern's own words
        def pattern_sentence(attribute, readable)
          named = Bluebook::NamedPattern::TABLE.key(attribute.pattern.to_s)
          return PATTERN_WORDS.fetch(:present) if readable.any? { |rule| reading(attribute, rule) == :not_blank }

          named && PATTERN_WORDS[named]
        end

        # Reads one invariant over the attribute alone.
        #
        # @return [String, Symbol, nil] a bound's words ("above zero"), `:not_blank`, or nil
        #   when the rule is not one this module can read
        def reading(attribute, rule)
          name = attribute.name.to_s
          canonical = rule.canonical.to_s.strip
          return :not_blank if blank_check?(name, canonical)
          return "above zero" if canonical == "#{name}.positive?"

          comparison_words(name, canonical)
        end

        # @return [Boolean] whether the rule refuses an empty or all-whitespace value
        def blank_check?(name, canonical)
          ["!#{name}.to_s.empty?", "!#{name}.to_s.strip.empty?", "!#{name}.empty?", "!#{name}.strip.empty?"]
            .include?(canonical)
        end

        # @return [String, nil] the comparison's words, with zero spelled out; nil when the
        #   rule is not one comparison of `name` against a number
        def comparison_words(name, canonical)
          match = COMPARISON.match(canonical)
          return nil unless match && match[:name] == name

          bound = match[:bound] == "0" ? "zero" : match[:bound]
          format(BOUND_WORDS.fetch(match[:op]), bound)
        end
      end
    end
  end
end
