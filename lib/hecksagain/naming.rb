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
