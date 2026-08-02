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
    # takes when an attribute declares one inline. Both runtimes derive it the
    # same way, or the same bluebook produces two different IRs.
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
    # derived their name with `"#{snake(target)}s"` in BOTH runtimes, so the
    # meta-domain's own whole-bluebook read model handed back `querys`, `entitys`,
    # `policys` and `dispatchs` — and bin/parity was green on every one of them,
    # because the two hand-written runtimes were identically wrong. Agreement is
    # not correctness; it never was.
    #
    # So: one pluraliser, and the Rust side mirrors these three rules exactly.
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
    # whole rule — the same one Rust's `parser::singularize` carries, mirrored
    # exactly so `has_many Invoices` resolves to the same target on both sides.
    def singularize(text)
      word = text.to_s
      return "#{word[0..-4]}y" if word.length > 3 && word.end_with?("ies")
      return word[0..-2]       if word.length > 1 && word.end_with?("s")

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
  end
end
