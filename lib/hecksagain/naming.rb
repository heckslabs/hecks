module Hecksagain
  module Naming
    module_function

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
