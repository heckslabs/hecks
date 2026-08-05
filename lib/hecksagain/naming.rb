module Hecksagain
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
      return word[0..-2]       if word.length > 1 && word.end_with?("s")

      word
    end

    def reference_key(type)
      snake(demodulise(type)).to_sym
    end

    # THE NAME A REFERENCE ANSWERS TO, PAST ITS OWN STORAGE SHAPE.
    #
    # `client_id` on Contract, target Client -> `client` — stripping the
    # storage-shape `_id` suffix is always safe, because the result can
    # never equal the raw attribute's own name (that name HAD the
    # suffix). `source` on Transfer (an `as:` reference, no `_id`
    # suffix), target Account -> `source_account`.
    #
    # NEVER collapse an `as:` name that already equals the target's own
    # snake case (`reference_to Studio, as: :studio`) down to the bare
    # name — caught for real, not hypothetically: `piece.studio` is a
    # doctested reader answering the raw id ("north:3"), and a first
    # draft of `Facade::Handle`'s own accessor silently redefined it to
    # answer a hydrated Studio instead. Suffixing unconditionally in
    # that branch keeps the two names distinct on purpose — `studio`
    # still reads the value, `studio_studio` reads the record.
    #
    # One rule, two callers: `Facade::Handle#define_reference_accessors`
    # (the Ruby accessor `piece.studio`) and a cross-aggregate query's
    # dotted hop (`:"studio_studio.x"`) name the same concept — a
    # reference spelled two ways was exactly the bug `IDENTITY_JOIN`'s
    # own comment above describes.
    def reference_hop(attribute_name, target_snake)
      base = attribute_name.to_s
      return base.delete_suffix("_id") if base.end_with?("_id")

      "#{base}_#{target_snake}"
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
  end
end
