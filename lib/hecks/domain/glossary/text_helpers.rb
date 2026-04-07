module Hecks
  class DomainGlossary
    # Hecks::DomainGlossary::TextHelpers
    #
    # English text utilities for glossary generation -- articles, pluralization,
    # humanization, and list formatting. Mixed into DomainGlossary and
    # StatementBuilders to produce grammatically correct sentences.
    #
    # These are simple heuristics, not a full NLP library. They handle the
    # common cases found in domain model names (PascalCase nouns).
    #
    module TextHelpers
      private

      # Return the indefinite article ("a" or "an") for a word based on
      # whether it starts with a vowel.
      #
      # @param word [String] the word to determine the article for
      # @return [String] "a" or "an"
      def article(word)
        %w[a e i o u].include?(word[0]&.downcase) ? "an" : "a"
      end

      # Prepend the indefinite article to a word. By default, capitalizes
      # the article ("A Pizza", "An Order"). Pass +capitalize: false+ for
      # lowercase ("a pizza", "an order").
      #
      # @param word [String] the word to prepend with an article
      # @param capitalize [Boolean] whether to capitalize the article (default true)
      # @return [String] the word with its article (e.g., "A Pizza" or "an order")
      def an(word, capitalize: true)
        article_word = article(word)
        article_word = article_word.capitalize if capitalize
        "#{article_word} #{word}"
      end

      # Naive English pluralization. Handles words ending in "y" (-> "ies")
      # and already-plural words ending in "s". All other words get "s" appended.
      #
      # @param word [String] the singular word to pluralize
      # @return [String] the pluralized word
      def pluralize(word)
        return word if word.end_with?("s")
        word.end_with?("y") ? word[0..-2] + "ies" : word + "s"
      end

      # Convert a PascalCase name to a lowercase, space-separated string.
      # Inserts a space before each uppercase letter.
      #
      # @param name [String] a PascalCase name (e.g., "FindByName")
      # @return [String] humanized form (e.g., "find by name")
      def humanize(name)
        Hecks::Utils.humanize(name).downcase
      end

      # Join an array of items into an English list with commas and "and".
      # Handles 0, 1, 2, and 3+ items with correct punctuation.
      #
      # @param items [Array<String>] the items to join
      # @return [String] formatted English list (e.g., "a, b, and c")
      def english_list(items)
        case items.size
        when 0 then ""
        when 1 then items[0]
        when 2 then "#{items[0]} and #{items[1]}"
        else "#{items[0..-2].join(', ')}, and #{items[-1]}"
        end
      end
    end
  end
end
