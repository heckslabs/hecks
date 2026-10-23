module Hecks
  module Bluebook
    module DSL
      # The `derive` and `rekey_to` words of a `.translation` aggregate block: the two rules that
      # compute from the record's own text and need no SQL.
      module DerivationWords
        # Declares a new field computed from the record's own text.
        #
        # The expression reads the held era's data, so it runs before any other rule and sees the
        # fields exactly as they were stored. It changes nothing it reads: remove a source with
        # `drop`. A record where the expression has no value (a field missing or not text) gets
        # no new field.
        #
        # @param to [Symbol, String] the field's path in the destination era
        # @param as [String] the expression, in `Bluebook::TranslationExpression`'s language
        # @return [Array<Bluebook::TranslationDerive>] every derive declared so far, this one last
        # @raise [Bluebook::DSL::Malformed] if `to` or `as` is empty, `to` is derived twice, or `as`
        #   is not a well-formed expression
        def derive_impl(to, as:)
          raise Malformed, "a derive needs a destination path" if to.to_s.empty?
          raise Malformed, "a derive needs its as: expression" if as.to_s.empty?
          raise Malformed, "#{to} is derived twice" if derived?(to)

          @derives << TranslationDerive.new(to.to_s, checked_expression(as))
        end

        # Declares that the aggregate's identity is the value of a field a `derive` computes.
        #
        # The id is that value for every record where the derive has a value, and stays what it was
        # for the rest.
        #
        # @param to [Symbol, String] the destination field of a `derive` declared earlier
        # @return [Array<Bluebook::TranslationRekey>] every rekey declared so far, this one last
        # @raise [Bluebook::DSL::Malformed] if `to` is empty, no earlier `derive` writes it, or the
        #   aggregate is already rekeyed
        def rekey_to_impl(to)
          raise Malformed, "a rekey_to needs the field to take the id from" if to.to_s.empty?
          raise Malformed, "rekey_to #{to} needs a derive of #{to} declared before it" unless derived?(to)
          raise Malformed, "an aggregate is rekeyed once" unless @rekeys.empty?

          @rekeys << TranslationRekey.new(to.to_s)
        end

        private

        def derived?(to) = @derives.any? { |derive| derive.to == to.to_s }

        # The expression's text, once the language has accepted it.
        def checked_expression(text)
          TranslationExpression.parse(text)
          text.to_s
        rescue TranslationExpression::Refused => e
          raise Malformed, "a derive's as: expression is refused: #{e.message}"
        end
      end
    end
  end
end
