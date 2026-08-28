module Hecks
  module Naming
    # WHAT SEPARATES THE PARTS OF A DERIVED IDENTITY.
    #
    # An identity of several parts is their JOIN, and the join has to be spelled the
    # same everywhere or two readers name two different records off one declaration.
    # It was spelled three ways at once here — "::" for an aggregate under a
    # chapter, "." for everything under an aggregate, "#" for the three that keyed
    # off position — and each was written where it happened to be needed. Once the
    # runtime derived the same identity, the runtime made a FOURTH, and a reference
    # that resolved by string comparison found nothing.
    IDENTITY_JOIN = ":".freeze

    module_function

    # The parts of an identity, joined in declaration order.
    def identity(parts) = Array(parts).join(IDENTITY_JOIN)

    def demodulise(type)
      type.to_s.split("::").last.to_s
    end

    # snake_case -> PascalCase. The name a synthesised closed-set value object
    # takes when an attribute declares one inline. The derivation is part of
    # the IR contract: the same bluebook must always produce the same name.
    def pascal(text)
      text.to_s.split("_").map { |part| part.sub(/\A(.)/) { Regexp.last_match(1).upcase } }.join
    end

    def snake(text)
      text.to_s
          .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
          .gsub(/([a-z\d])([A-Z])/, '\1_\2')
          .downcase
    end

    # The name a COLLECTION of something takes.
    #
    # There were two of these and one was wrong. A read model's gathered heads
    # derived their name with a bare `"#{snake(target)}s"`, so the meta-domain's
    # own whole-bluebook read model handed back `querys`, `entitys`, `policys`
    # and `dispatchs` — and every check was green, because the checks compared
    # the wrong rule against itself. Agreement is not correctness; it never was.
    #
    # So: one pluraliser, three rules, and every collection name flows through it.
    def plural(text)
      word = text.to_s
      return "#{word[0..-2]}ies" if word.match?(/[^aeiou]y\z/)
      return "#{word}es"         if word.match?(/(s|x|z|ch|sh)\z/)

      "#{word}s"
    end

    # `has_many`'s undo — the plural WRITTEN, back to the singular the target
    # aggregate is actually named. Deliberately the crude half of a pair: `plural`
    # above earns its precision (three suffix rules) because getting a COLLECTION
    # name wrong reads as a typo forever ; this only ever recovers a name someone
    # already wrote as a real aggregate, so "ies -> y, trailing s dropped" is the
    # whole rule — enough for `has_many Invoices` to resolve to the aggregate
    # actually named Invoice.
    def singularize(text)
      word = text.to_s
      return "#{word[0..-4]}y" if word.length > 3 && word.end_with?("ies")

      # `plural`'s OWN second rule adds "es" (not bare "s") after
      # s/x/z/ch/sh — undone here the same way, or a word `plural`
      # itself would have suffixed with "es" comes back missing its
      # own trailing letter ("Boxes" -> "Boxe", not "Box") once this
      # only ever knew how to drop a bare "s". Checked BEFORE the
      # bare-"s" rule below: stripping "es" first and confirming what
      # is left actually ends in one of those five shapes is what
      # keeps an ordinary "-es" word (e.g. "Invoices" -> "Invoice")
      # from also losing a letter it never doubled.
      if word.length > 3 && word.end_with?("es") && word[0..-3].match?(/(s|x|z|ch|sh)\z/)
        return word[0..-3]
      end

      return word[0..-2] if word.length > 1 && word.end_with?("s")

      word
    end

    def reference_key(type)
      snake(demodulise(type)).to_sym
    end

    def split_dotted(dotted)
      first, second = dotted.to_s.split(".", 2)
      [first.to_s, second.to_s]
    end

    def qualifier(dotted)
      text = dotted.to_s
      text.include?(".") ? text.split(".", 2).first : nil
    end

    def unqualified(dotted)
      text = dotted.to_s
      text.include?(".") ? text.split(".", 2).last : text
    end

    def split_verb(verb)
      path, command = verb.to_s.split(".", 2)
      domain, aggregate = path.to_s.split("::", 2)
      return nil unless domain && aggregate && command

      [domain, aggregate, command]
    end

    # `trigger Account::Debit` / `dispatch Account::Debit` — a bare
    # CONSTANT reference (`ConstShim`'s own `ScopedConstant`, S0b), not
    # text (ADR 0025, "events and reactions" — command references become
    # first-class). Ruby's `::` joins EVERY segment the same way a
    # constant path always does, but a command's own `hecks_fqn` joins
    # its aggregate with `.` (`Construct#hecks_separator`'s default,
    # only an AGGREGATE overrides it to `::`) — so only the LAST `::`
    # becomes a `.`; everything before it (the chapter, when a domain is
    # spelled at all: `Banking::Account::Debit`) stays `::`-joined.
    #
    # A STRING PASSES THROUGH UNCHANGED, on purpose — legacy era text
    # (S0a's own shadow-parsed spelling) already mixes `::` (domain) and
    # `.` (command) correctly on its own, e.g. `"Banking::Account.Debit"`,
    # and re-splitting that by content rather than by TYPE would corrupt
    # it (its own last `::` sits between the domain and the aggregate,
    # not the aggregate and the command). Only an actual constant object
    # — never seen holding a `.` of its own — needs the rewrite at all.
    def command_ref(value)
      return value.to_s if value.is_a?(::String) || value.is_a?(::Symbol)

      text = value.to_s
      path, _, command = text.rpartition("::")
      path.empty? ? text : "#{path}.#{command}"
    end

    # `emits Account::AccountFrozen` / `on Account::AccountFrozen` — the
    # event-side twin of `command_ref`, above (ADR 0025, S6 — "events
    # first-class"). Identical transform (a bare `ScopedConstant`'s last
    # `::` becomes `.`, a String passes through unchanged for legacy
    # `shadow_parse` text and for corpus sites this pass didn't migrate —
    # see that method's own comment for why both rules exist), given its
    # own name because the two references mean different things even
    # though the rewrite is byte-identical: an event name is not a
    # command name that happens to share a format.
    def event_ref(value) = command_ref(value)

    # `transition Account::AccountDebited => "state"` / `starts_on
    # Transfer::TransferRequested` / `ends_on Transfer::TransferSettled`
    # — a process manager's OWN event references (ADR 0025, S6),
    # DELIBERATELY NOT `event_ref` — found live, not assumed, wiring a
    # real migrated corpus site into `bin/model_check` for the first
    # time (2026-08-28): `SagaInterpreter#begin_saga`/`#advance_saga`
    # match `pm.starts_on`/`pm.handler_for` against `event.name`, which
    # `CommandRules::Emission#emit` stamps BARE — a command's own
    # `emits AccountDebited` never carries its aggregate's name at all
    # (unlike a policy's cross-aggregate `on`, matched instead by
    # `Naming.demodulise(event.aggregate)` split apart from the bare
    # name — `PolicyInterpreter#policies_for`). Handing a saga's own
    # matcher the DOTTED `event_ref` form ("Account.AccountDebited")
    # would silently name an event no command in the domain ever
    # actually emits — caught by `bin/model_check`'s own `deaf_handler`/
    # `deaf_trigger` findings the moment a real qualified corpus site
    # existed to trip them, not by any unit test in isolation.
    #
    # A qualifier is still worth WRITING (`Account::`) — the same
    # provenance a reader gets from `trigger Account::Debit` — it is
    # only not worth KEEPING: `demodulise` drops everything but the
    # final segment, so `Account::AccountDebited` and a bare
    # `AccountDebited` resolve to the identical stored string. A String
    # passes through unchanged either way, exactly like `command_ref`'s
    # own legacy branch — this corpus never spelled one dotted to begin
    # with, so there is nothing here to strip.
    def event_name_ref(value) = demodulise(value)
  end
end
