module Hecks
  # Derived-name and identity-joining rules: casing, pluralisation, dotted-path
  # and verb splitting, command/event reference rewrites.
  module Naming
    # What separates the parts of a derived identity. Every reader must spell the
    # join the same way, or string-compared references resolve to nothing.
    IDENTITY_JOIN = ":".freeze

    # An uppercase run followed by a capitalised word: the "M|C" in "ATMCard".
    ACRONYM_BOUNDARY = /([A-Z]+)([A-Z][a-z])/

    # A lowercase letter or digit followed by an uppercase letter: the "y|L" in "dailyLimit".
    CAMEL_BOUNDARY = /([a-z\d])([A-Z])/

    # The first character of a word, captured.
    FIRST_CHARACTER = /\A(.)/

    # A word of two or more capitals and nothing else: an acronym such as "ATM".
    ACRONYM = /\A[A-Z]{2,}\z/

    # A consonant followed by a final "y", as in "category".
    CONSONANT_Y_ENDING = /[^aeiou]y\z/

    # A final s, x, z, ch or sh: the endings whose plural takes "es".
    SIBILANT_ENDING = /(s|x|z|ch|sh)\z/

    module_function

    # Joins the parts of an identity in declaration order.
    #
    # @param parts [Array<#to_s>, #to_s] one or more identity segments; a bare
    #   value is wrapped in a single-element Array
    # @return [String] the segments joined with `IDENTITY_JOIN`
    def identity(parts) = Array(parts).join(IDENTITY_JOIN)

    # Strips a namespace path down to its last segment.
    #
    # @param type [Module, String, Symbol, #to_s] a `::`-joined constant path, or
    #   anything whose `to_s` is one
    # @return [String] the text after the last `::`, or the whole `to_s` if there
    #   is none
    def demodulise(type)
      last_segment = type.to_s.split("::").last
      last_segment.to_s
    end

    # snake_case -> PascalCase. Names a closed-set value object synthesised from an
    # inline attribute; the derivation is part of the IR contract.
    #
    # @param text [String, Symbol, #to_s] a snake_case (or already Pascal) name
    # @return [String] the PascalCase form
    def pascal(text)
      parts = text.to_s.split("_")
      parts.map { |part| part.sub(FIRST_CHARACTER) { Regexp.last_match(1).upcase } }.join
    end

    # PascalCase or camelCase -> snake_case.
    #
    # @param text [String, Symbol, #to_s] a Pascal-, camel-, or already snake-case name
    # @return [String] the lowercase, underscore-separated form
    def snake(text)
      split_case(text, "_").downcase
    end

    # Puts `separator` at every case boundary of an identifier: before the capitalised word
    # after an acronym, and between a lowercase letter or digit and the capital that follows.
    #
    # @param text [String, Symbol, #to_s] a Pascal- or camel-case name
    # @param separator [String] what to put at each boundary, such as `"_"` or `" "`
    # @return [String] the name with `separator` at each boundary, case unchanged
    def split_case(text, separator)
      replacement = "\\1#{separator}\\2"
      acronyms_apart = text.to_s.gsub(ACRONYM_BOUNDARY, replacement)
      acronyms_apart.gsub(CAMEL_BOUNDARY, replacement)
    end

    # An identifier as a sentence-cased phrase: `ATMCard` -> "ATM card",
    # `daily_limit` -> "Daily limit". All-caps runs stay acronyms.
    #
    # @param text [String, Symbol, #to_s] a Pascal-, camel-, or snake-case identifier
    # @return [String] the space-separated, sentence-cased phrase
    def words(text)
      parts = split_case(text.to_s.tr("_", " "), " ").split
      parts.each_with_index.map do |part, index|
        next part if part.match?(ACRONYM)

        index.zero? ? part.capitalize : part.downcase
      end.join(" ")
    end

    # Joins items into an Oxford-comma list: "A, B, and C" / "A or B".
    #
    # @param items [Array<#to_s>] the items to join
    # @param conj [String] the word before the last item, such as `"and"` or `"or"`
    # @return [String] `""` for no items, the item's `to_s` for one, and the
    #   Oxford-comma join for more
    def to_sentence_list(items, conj: "and")
      case items.size
      when 0 then ""
      when 1 then items[0].to_s
      when 2 then "#{items[0]} #{conj} #{items[1]}"
      else "#{items[0..-2].join(", ")}, #{conj} #{items[-1]}"
      end
    end

    # Picks the article for `word` by its first letter. Construct names are plain
    # words, never "hour" or "university", so the vowel-letter heuristic holds.
    #
    # @param word [String, Symbol, #to_s] the word the article precedes
    # @return [String] `"an"` if `word` starts with a vowel letter, `"a"` otherwise
    def a_or_an(word)
      %w[a e i o u].include?(word.to_s[0].to_s.downcase) ? "an" : "a"
    end

    # The name a collection of something takes: "y" -> "ies", sibilants take "es",
    # everything else "s". Every collection name must flow through this one rule.
    #
    # @param text [String, Symbol, #to_s] a singular name
    # @return [String] the pluralised name
    def plural(text)
      word = text.to_s
      return "#{word[0..-2]}ies" if word.match?(CONSONANT_Y_ENDING)
      return "#{word}es"         if word.match?(SIBILANT_ENDING)

      "#{word}s"
    end

    # Recovers the singular aggregate name from a `has_many` plural. Deliberately
    # crude ("ies" -> "y", sibilant "es" and trailing "s" dropped): it only has to
    # find a name someone already wrote.
    #
    # @param text [String, Symbol, #to_s] a plural name
    # @return [String] the singularised name
    def singularize(text)
      word = text.to_s
      return "#{word[0..-4]}y" if word.length > 3 && word.end_with?("ies")

      # Undo `plural`'s "es" after s/x/z/ch/sh before the bare-"s" rule, so "Boxes"
      # gives "Box" while "Invoices" still gives "Invoice".
      return word[0..-3] if sibilant_es?(word)

      return word[0..-2] if word.length > 1 && word.end_with?("s")

      word
    end

    # @param word [String] a plural name
    # @return [Boolean] whether it is a sibilant stem plus `plural`'s "es"
    def sibilant_es?(word)
      word.length > 3 && word.end_with?("es") && word[0..-3].match?(SIBILANT_ENDING)
    end

    # Derives the attribute name a reference to `type` is stored under.
    #
    # @param type [Module, String, Symbol, #to_s] the referenced construct's name
    #   or a `::`-joined path to it
    # @return [Symbol] the snake_case, demodulised name, as a Symbol
    def reference_key(type)
      snake(demodulise(type)).to_sym
    end

    # Splits a `qualifier.name` string on its first dot.
    #
    # @param dotted [String, Symbol, #to_s] text, optionally containing a dot
    # @return [Array(String, String)] `[before the first dot, after it]`; the
    #   second element is `""` when `dotted` has no dot
    def split_dotted(dotted)
      first, second = dotted.to_s.split(".", 2)
      [first.to_s, second.to_s]
    end

    # The part of a dotted name before its first dot.
    #
    # @param dotted [String, Symbol, #to_s] text, optionally containing a dot
    # @return [String, nil] the text before the first dot, or nil if `dotted`
    #   has no dot
    def qualifier(dotted)
      text = dotted.to_s
      text.include?(".") ? text.split(".", 2).first : nil
    end

    # The part of a dotted name after its first dot.
    #
    # @param dotted [String, Symbol, #to_s] text, optionally containing a dot
    # @return [String] the text after the first dot, or the whole text if
    #   `dotted` has no dot
    def unqualified(dotted)
      text = dotted.to_s
      text.include?(".") ? text.split(".", 2).last : text
    end

    # Splits a domain-qualified verb into its domain, aggregate, and command parts.
    #
    # A `::` left after the domain and aggregate is the last-`::`-to-`.` rewrite
    # `command_ref` leaves on a port operation; it folds into the dotted command
    # tail (`Aggregate::Port.Operation`).
    #
    # @param verb [String, Symbol, #to_s] a `Domain::Aggregate.command` (or
    #   `.query`) path
    # @return [Array(String, String, String), nil] `[domain, aggregate, command]`,
    #   or nil if `verb` has no `.` or no `domain::aggregate` before it
    def split_verb(verb)
      path, command = verb.to_s.split(".", 2)
      return nil unless path && command

      domain, aggregate, *rest = path.to_s.split("::")
      return nil unless domain && aggregate

      command = "#{rest.join(".")}.#{command}" unless rest.empty?

      [domain, aggregate, command]
    end

    # Rewrites a bare command constant's last `::` into `.`, matching a command's
    # FQN separator (`Banking::Account::Debit` -> `Banking::Account.Debit`).
    #
    # A String or Symbol passes through: era text already mixes `::` and `.`
    # correctly, and re-splitting it by content would corrupt it.
    #
    # @param value [Symbol, String, Module] the command, as a bare constant (a
    #   `ScopedConstant` module `ConstShim` resolves) or already-dotted text
    # @return [String] the dotted command reference
    def command_ref(value)
      return value.to_s if value.is_a?(::String) || value.is_a?(::Symbol)

      text = value.to_s
      path, _, command = text.rpartition("::")
      path.empty? ? text : "#{path}.#{command}"
    end

    # The event-side twin of `command_ref`. Same rewrite, separate name, because an
    # event reference is not a command reference that happens to share a format.
    #
    # @param value [Symbol, String, Module] the event, as a bare constant (a
    #   `ScopedConstant` module `ConstShim` resolves) or already-dotted text
    # @return [String] the dotted event reference
    def event_ref(value) = command_ref(value)

    # Strips a process manager's event reference down to its bare event name.
    #
    # Not `event_ref`: saga matching compares against `event.name`, which is stamped
    # bare, so a dotted "Account.AccountDebited" would name an event nothing emits.
    #
    # @param value [Symbol, String, Module] the event, as a bare constant (a
    #   `ScopedConstant` module `ConstShim` resolves) or already-dotted text
    # @return [String] the bare event name, with any qualifier stripped
    def event_name_ref(value) = demodulise(value)
  end
end
