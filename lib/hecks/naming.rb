module Hecks
  # Every derived-name and identity-joining rule the language relies on —
  # pluralisation/singularisation, snake/Pascal casing, dotted-path and verb
  # splitting, and the command/event reference rewrites — collected here so
  # two readers never invent two different spellings for the same
  # derivation.
  module Naming
    # What separates the parts of a derived identity.
    #
    # An identity of several parts is their join, and the join has to be spelled the
    # same everywhere or two readers name two different records off one declaration.
    # It was spelled three ways at once here — "::" for an aggregate under a
    # chapter, "." for everything under an aggregate, "#" for the three that keyed
    # off position — and each was written where it happened to be needed. Once the
    # runtime derived the same identity, the runtime made a fourth, and a reference
    # that resolved by string comparison found nothing.
    IDENTITY_JOIN = ":".freeze

    module_function

    # The parts of an identity, joined in declaration order.
    #
    # @param parts [Array<#to_s>, nil] the identity's components; nil is treated as empty
    # @return [String] `parts` joined by `IDENTITY_JOIN`
    def identity(parts) = Array(parts).join(IDENTITY_JOIN)

    # Strips every namespace off a constant path, leaving the final segment.
    #
    # @param type [String, Symbol, Module, #to_s] a constant path such as `"Foo::Bar"`
    # @return [String] the last `::`-separated segment, `""` for a nil or empty input
    def demodulise(type)
      type.to_s.split("::").last.to_s
    end

    # Converts snake_case to PascalCase.
    #
    # The name a synthesised closed-set value object takes when an attribute
    # declares one inline. The derivation is part of the IR contract: the
    # same bluebook must always produce the same name.
    #
    # @param text [String, Symbol, #to_s] snake_case (or already-Pascal) text
    # @return [String] the PascalCase form
    def pascal(text)
      text.to_s.split("_").map { |part| part.sub(/\A(.)/) { Regexp.last_match(1).upcase } }.join
    end

    # Converts PascalCase or camelCase to snake_case.
    #
    # @param text [String, Symbol, #to_s] text to convert
    # @return [String] the snake_case form
    def snake(text)
      text.to_s
          .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
          .gsub(/([a-z\d])([A-Z])/, '\1_\2')
          .downcase
    end

    # Renders an identifier the way a person would say it.
    #
    # An identifier as a person would say it — `ATMCard` -> "ATM card",
    # `AccrueInterest` -> "Accrue interest", `daily_limit` -> "Daily
    # limit", `Back office` -> "Back office". The same two word-boundary
    # splits `snake` uses, with a space instead of an underscore — plus
    # the one thing `snake` cannot give back: an all-caps run stays an
    # acronym ("ATM", "KYC") instead of being lowercased into a word
    # nobody says ("Atm"). First word capitalized, the rest lowercased,
    # so a headword reads as sentence case whatever casing it was
    # declared in.
    #
    # @param text [String, Symbol, #to_s] identifier to render
    # @return [String] the space-joined, sentence-cased rendering
    def words(text)
      parts = text.to_s
                  .tr("_", " ")
                  .gsub(/([A-Z]+)([A-Z][a-z])/, '\1 \2')
                  .gsub(/([a-z\d])([A-Z])/, '\1 \2')
                  .split
      parts.each_with_index.map do |part, index|
        next part if part.match?(/\A[A-Z]{2,}\z/)

        index.zero? ? part.capitalize : part.downcase
      end.join(" ")
    end

    # Joins `items` into an English list with an Oxford comma.
    #
    # "A, B, and C" / "A or B" — the Oxford-comma list every English
    # sentence a projection writes wants; lived in `NarrateProjector`
    # alone until a second projection needed it.
    #
    # @param items [Array<#to_s>] items to join, in order
    # @param conj [String] conjunction placed before the last item
    # @return [String] the joined sentence fragment, `""` for an empty `items`
    def to_sentence_list(items, conj: "and")
      case items.size
      when 0 then ""
      when 1 then items[0].to_s
      when 2 then "#{items[0]} #{conj} #{items[1]}"
      else "#{items[0..-2].join(', ')}, #{conj} #{items[-1]}"
      end
    end

    # Picks the English indefinite article for `word`.
    #
    # The vowel-letter heuristic — safe here for the same reason
    # `Projections::Statements#article` gives: a construct name is a
    # plain word, never "hour" or "university".
    #
    # @param word [String, Symbol, #to_s] the word the article precedes
    # @return [String] `"a"` or `"an"`
    def a_or_an(word)
      %w[a e i o u].include?(word.to_s[0].to_s.downcase) ? "an" : "a"
    end

    # Pluralises `text` into the name its collection takes.
    #
    # There were two of these and one was wrong. A read model's gathered heads
    # derived their name with a bare `"#{snake(target)}s"`, so the meta-domain's
    # own whole-bluebook read model handed back `querys`, `entitys`, `policys`
    # and `dispatchs` — and every check was green, because the checks compared
    # the wrong rule against itself. Agreement is not correctness; it never was.
    #
    # So: one pluraliser, three rules, and every collection name flows through it.
    #
    # @param text [String, Symbol, #to_s] the singular name to pluralise
    # @return [String] the pluralised name
    def plural(text)
      word = text.to_s
      return "#{word[0..-2]}ies" if word.match?(/[^aeiou]y\z/)
      return "#{word}es"         if word.match?(/(s|x|z|ch|sh)\z/)

      "#{word}s"
    end

    # Singularises `text`, the crude undo of `plural`.
    #
    # `has_many`'s undo — the plural written, back to the singular the target
    # aggregate is actually named. Deliberately the crude half of a pair: `plural`
    # above earns its precision (three suffix rules) because getting a collection
    # name wrong reads as a typo forever ; this only ever recovers a name someone
    # already wrote as a real aggregate, so "ies -> y, trailing s dropped" is the
    # whole rule — enough for `has_many Invoices` to resolve to the aggregate
    # actually named Invoice.
    #
    # @param text [String, Symbol, #to_s] the plural name to singularise
    # @return [String] the singularised name
    def singularize(text)
      word = text.to_s
      return "#{word[0..-4]}y" if word.length > 3 && word.end_with?("ies")

      # `plural`'s own second rule adds "es" (not bare "s") after
      # s/x/z/ch/sh — undone here the same way, or a word `plural`
      # itself would have suffixed with "es" comes back missing its
      # own trailing letter ("Boxes" -> "Boxe", not "Box") once this
      # only ever knew how to drop a bare "s". Checked before the
      # bare-"s" rule below: stripping "es" first and confirming what
      # is left actually ends in one of those five shapes is what
      # keeps an ordinary "-es" word (e.g. "Invoices" -> "Invoice")
      # from also losing a letter it never doubled.
      return word[0..-3] if word.length > 3 && word.end_with?("es") && word[0..-3].match?(/(s|x|z|ch|sh)\z/)

      return word[0..-2] if word.length > 1 && word.end_with?("s")

      word
    end

    # Derives the Hash key a reference to `type` is stored under.
    #
    # @param type [String, Symbol, Module, #to_s] a constant path such as `"Foo::Bar"`
    # @return [Symbol] `type`'s final segment, snake_cased
    def reference_key(type)
      snake(demodulise(type)).to_sym
    end

    # Splits `dotted` on its first `.` into two parts.
    #
    # @param dotted [String, Symbol, #to_s] text such as `"Account.Opened"`
    # @return [Array(String, String)] the part before the first `.`, and the part
    #   after it (`""` when `dotted` has no `.`)
    def split_dotted(dotted)
      first, second = dotted.to_s.split(".", 2)
      [first.to_s, second.to_s]
    end

    # Extracts the qualifier before a reference's first `.`.
    #
    # @param dotted [String, Symbol, #to_s] text such as `"Account.Opened"`
    # @return [String, nil] the part before the first `.`, or nil when `dotted` has none
    def qualifier(dotted)
      text = dotted.to_s
      text.include?(".") ? text.split(".", 2).first : nil
    end

    # Strips the qualifier from a reference, if it has one.
    #
    # @param dotted [String, Symbol, #to_s] text such as `"Account.Opened"`
    # @return [String] the part after the first `.`, or `dotted` unchanged when it has none
    def unqualified(dotted)
      text = dotted.to_s
      text.include?(".") ? text.split(".", 2).last : text
    end

    # Splits a domain-qualified command path into domain, aggregate, and verb.
    #
    # Domain, aggregate, then the REST dot-joined into one command path.
    #
    # The `::` boundary between domain and aggregate is unambiguous by
    # construction — every caller here has already prefixed the domain
    # itself (`PolicyInterpreter#deliver`, `SagaInterpreter#qualified`,
    # `Router#dispatch`'s own rebuilt string) before this ever runs. A
    # third `::` segment can still show up past that boundary: a bare
    # `ScopedConstant` naming a port operation (`command_ref`'s own
    # comment — `Aggregate::Port::Operation`, three colon-joined
    # segments with no `.` of its own) only gets its last `::` rewritten
    # to `.` there, at DSL-build time, because nothing at that point
    # knows yet whether the constant names a port operation or a
    # domain-qualified command (`Domain::Aggregate::Command`, the other
    # shape `command_ref` documents) — both are textually identical.
    # Here, past the already-resolved domain boundary, any leftover
    # `::` is unambiguous: it is that same rewrite artifact, and folding
    # it into the dot-joined tail recovers exactly the
    # `Aggregate::Port.Operation` shape a working port dispatch already
    # expects (`spec/port_operation_interpreter_spec.rb`'s own
    # `"Payments::Payment.PaymentGateway.Receive"`). `Outbox::Fanout
    # .kind_for` and `ReactionInvocation#resolve_target` both already
    # assume this contract on their own end; this is what actually
    # delivers it to them.
    #
    # @param verb [String, Symbol, #to_s] a domain-qualified command path such as
    #   `"Pizzas::Pizza.Purchase"`
    # @return [Array(String, String, String), nil] domain, aggregate, and verb
    #   (dot-joined with any leftover `::` segments folded in), or nil when `verb`
    #   has no `.` or no domain/aggregate pair before it
    def split_verb(verb)
      path, command = verb.to_s.split(".", 2)
      return nil unless path && command

      domain, aggregate, *rest = path.to_s.split("::")
      return nil unless domain && aggregate

      command = "#{rest.join('.')}.#{command}" unless rest.empty?

      [domain, aggregate, command]
    end

    # Rewrites a bare constant reference's trailing `::` into a `.`, the
    # separator a command's `hecks_fqn` actually uses.
    #
    # `trigger Account::Debit` / `dispatch Account::Debit` — a bare
    # constant reference (`ConstShim`'s own `ScopedConstant`, S0b), not
    # text (ADR 0025, "events and reactions" — command references become
    # first-class). Ruby's `::` joins every segment the same way a
    # constant path always does, but a command's own `hecks_fqn` joins
    # its aggregate with `.` (`Construct#hecks_separator`'s default,
    # only an aggregate overrides it to `::`) — so only the last `::`
    # becomes a `.`; everything before it (the chapter, when a domain is
    # spelled at all: `Banking::Account::Debit`) stays `::`-joined.
    #
    # A string passes through unchanged, on purpose — legacy era text
    # (S0a's own shadow-parsed spelling) already mixes `::` (domain) and
    # `.` (command) correctly on its own, e.g. `"Banking::Account.Debit"`,
    # and re-splitting that by content rather than by type would corrupt
    # it (its own last `::` sits between the domain and the aggregate,
    # not the aggregate and the command). Only an actual constant object
    # — never seen holding a `.` of its own — needs the rewrite at all.
    #
    # @param value [String, Symbol, Module] a `ScopedConstant`, or already-formatted text
    # @return [String] the rewritten reference, or `value.to_s` unchanged when it was
    #   already a String or Symbol
    def command_ref(value)
      return value.to_s if value.is_a?(::String) || value.is_a?(::Symbol)

      text = value.to_s
      path, _, command = text.rpartition("::")
      path.empty? ? text : "#{path}.#{command}"
    end

    # Rewrites an event reference the same way `command_ref` does.
    #
    # `emits Account::AccountFrozen` / `on Account::AccountFrozen` — the
    # event-side twin of `command_ref`, above (ADR 0025, S6 — "events
    # first-class"). Identical transform (a bare `ScopedConstant`'s last
    # `::` becomes `.`, a String passes through unchanged for legacy
    # `shadow_parse` text and for corpus sites this pass didn't migrate —
    # see that method's own comment for why both rules exist), given its
    # own name because the two references mean different things even
    # though the rewrite is byte-identical: an event name is not a
    # command name that happens to share a format.
    #
    # @param value [String, Symbol, Module] a `ScopedConstant`, or already-formatted text
    # @return [String] the rewritten reference, or `value.to_s` unchanged when it was
    #   already a String or Symbol
    def event_ref(value) = command_ref(value)

    # Reduces a process-manager event reference to its bare event name.
    #
    # `transition Account::AccountDebited => "state"` / `starts_on
    # Transfer::TransferRequested` / `ends_on Transfer::TransferSettled`
    # — a process manager's own event references (ADR 0025, S6),
    # deliberately not `event_ref` — found live, not assumed, wiring a
    # real migrated corpus site into `bin/model_check` for the first
    # time (2026-08-28): `SagaInterpreter#begin_saga`/`#advance_saga`
    # match `pm.starts_on`/`pm.handler_for` against `event.name`, which
    # `CommandRules::Emission#emit` stamps bare — a command's own
    # `emits AccountDebited` never carries its aggregate's name at all
    # (unlike a policy's cross-aggregate `on`, matched instead by
    # `Naming.demodulise(event.aggregate)` split apart from the bare
    # name — `PolicyInterpreter#policies_for`). Handing a saga's own
    # matcher the dotted `event_ref` form ("Account.AccountDebited")
    # would silently name an event no command in the domain ever
    # actually emits — caught by `bin/model_check`'s own `deaf_handler`/
    # `deaf_trigger` findings the moment a real qualified corpus site
    # existed to trip them, not by any unit test in isolation.
    #
    # A qualifier is still worth writing (`Account::`) — the same
    # provenance a reader gets from `trigger Account::Debit` — it is
    # only not worth keeping: `demodulise` drops everything but the
    # final segment, so `Account::AccountDebited` and a bare
    # `AccountDebited` resolve to the identical stored string. A String
    # passes through unchanged either way, exactly like `command_ref`'s
    # own legacy branch — this corpus never spelled one dotted to begin
    # with, so there is nothing here to strip.
    #
    # @param value [String, Symbol, Module, #to_s] a `ScopedConstant`, or already-formatted text
    # @return [String] the event's bare (unqualified) name
    def event_name_ref(value) = demodulise(value)
  end
end
