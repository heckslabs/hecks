require_relative "../naming"

module Hecks
  module Projections
    # The few pieces of English grammar the statements and the glossary share: how a construct
    # name is spoken as a noun, and how a command is spoken as something being done.
    #
    #   PlainEnglish.doing("AddTopping", "Order") # => "adding a topping"
    #   PlainEnglish.doing("Purchase", "Order")   # => "purchasing an order"
    module PlainEnglish
      # Nouns that take no article: "accruing interest", never "accruing an interest".
      UNCOUNTED = %w[interest money cash information data feedback equipment evidence].freeze

      # Two-syllable verbs stressed on the last syllable, which double their final consonant.
      DOUBLED = %w[submit commit admit permit omit refer prefer transfer occur control patrol compel
                   expel regret equip rebut forget begin cancel].freeze

      # One-word verbs that act on their holder through a preposition: "withdrawing from a
      # card", never "withdrawing a card".
      THROUGH = { "withdraw" => "from", "deposit" => "into" }.freeze

      # Verbs written as one word whose "-ing" form splits back into a verb and a particle.
      PHRASAL = {
        "chargeback" => "charging back", "rollback" => "rolling back", "backup" => "backing up",
        "setup" => "setting up", "signup" => "signing up", "checkout" => "checking out",
        "login" => "logging in", "logout" => "logging out", "payout" => "paying out"
      }.freeze

      # A word of two or more capitals, spoken as an acronym: "ATM".
      ACRONYM = /\A[A-Z]{2,}\z/
      # The lowercase letter a text opens with.
      LEADING_LOWER = /\A[[:lower:]]/
      # A verb ending in a silent "e" after a consonant: "purchase", "make".
      SILENT_E = /[^aeiouy]e\z/
      # A one-syllable verb closed by one plain consonant after one vowel: "log", "set".
      SHORT_CLOSED = /\A[^aeiou]*[aeiou][bdgklmnprt]\z/

      module_function

      # A construct name as a lowercase noun phrase; acronyms keep their capitals.
      #
      # @param name [String, Symbol] a construct or field name, such as `ATMCard` or `daily_limit`
      # @return [String] the spoken noun, such as "ATM card" or "daily limit"
      def noun(name)
        words = Naming.words(name).split
        words.map { |word| word.match?(ACRONYM) ? word : word.downcase }.join(" ")
      end

      # @param phrase [String] a spoken noun phrase
      # @return [String] the phrase with its indefinite article, such as "an order"
      def a(phrase) = "#{Naming.a_or_an(phrase)} #{phrase}"

      # @param phrase [String] a spoken noun phrase
      # @return [String] the phrase with its last word pluralised, such as "ATM cards"
      def plural(phrase)
        *head, last = phrase.split
        [*head, Naming.plural(last)].join(" ")
      end

      # A state name as it is said: `charged_back` -> "charged back".
      def state(name) = name.to_s.tr("_", " ")

      # @param states [Array<String>] state names
      # @return [String] the spoken states joined with "or"
      def states(states) = Naming.to_sentence_list(states.map { |name| state(name) }, conj: "or")

      # @param text [String] a sentence fragment
      # @return [String] the fragment with its first letter capitalised
      def upper(text) = text.sub(LEADING_LOWER, &:upcase)

      # A command as the act of doing it. A one-word command takes its holder as the object;
      # a command named as a past state ("Debited") reads as marking the holder so.
      #
      # @param command_name [String] the command's name, such as `AddTopping`
      # @param holder_name [String] the aggregate or entity the command is declared on
      # @return [String] the lowercase phrase, such as "adding a topping"
      def doing(command_name, holder_name)
        verb, *rest = noun(command_name).split
        holder = a(noun(holder_name))
        return "marking #{holder} #{[verb, *rest].join(" ")}" if verb.end_with?("ed")
        return [gerund(verb), THROUGH[verb], holder].compact.join(" ") if rest.empty?

        "#{gerund(verb)} #{object(rest.join(" "))}"
      end

      # @param phrase [String] the words after a command's verb
      # @return [String] the phrase with an article, unless it names something uncounted
      def object(phrase) = UNCOUNTED.include?(phrase.split.last) ? phrase : a(phrase)

      # The "-ing" form of a plain verb.
      #
      # @param verb [String] a lowercase verb, such as "purchase" or "log"
      # @return [String] its "-ing" form, such as "purchasing" or "logging"
      def gerund(verb)
        return PHRASAL[verb] if PHRASAL.key?(verb)
        return "#{verb[0..-3]}ying" if verb.end_with?("ie")
        return "#{verb[0..-2]}ing" if verb.match?(SILENT_E) || verb.end_with?("ue")
        return "#{verb}#{verb[-1]}ing" if doubles?(verb)

        "#{verb}ing"
      end

      # One vowel then one plain consonant ("log", "set") doubles; so do the stressed `DOUBLED`.
      def doubles?(verb) = DOUBLED.include?(verb) || verb.match?(SHORT_CLOSED)
    end
  end
end
