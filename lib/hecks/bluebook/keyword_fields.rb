module Hecks
  module Bluebook
    # The optional keywords of a wide IR constructor, held as a default table instead of a
    # signature, so the constructor names only its required keywords and stays short.
    #
    # A constructor declares `FIELD_DEFAULTS`, takes `name:, **given`, and calls `fill` then
    # `assign`. An unknown keyword raises `ArgumentError`, as a literal signature would.
    module KeywordFields
      # Merges the caller's keywords over the defaults, giving each omitted keyword its own copy
      # of the default so a default `[]` or `{}` is never shared between instances.
      #
      # @param given [Hash{Symbol => Object}] the optional keywords the caller passed
      # @param defaults [Hash{Symbol => Object}] every accepted optional keyword and its default
      # @return [Hash{Symbol => Object}] one entry per accepted keyword
      # @raise [ArgumentError] when `given` carries a keyword `defaults` does not name
      def self.fill(given, defaults)
        unknown = given.keys - defaults.keys
        reject_unknown(unknown) unless unknown.empty?

        defaults.to_h { |key, default| [key, given.fetch(key) { default.dup }] }
      end

      # Stores each field as the instance variable of the same name.
      #
      # @param target [Object] the instance being built
      # @param fields [Hash{Symbol => Object}] the filled keywords
      # @return [void]
      def self.assign(target, fields)
        fields.each { |key, value| target.instance_variable_set(:"@#{key}", value) }
      end

      # @param unknown [Array<Symbol>] the keywords no default names
      # @raise [ArgumentError] always, worded as Ruby words a literal signature's refusal
      def self.reject_unknown(unknown)
        plural = "s" if unknown.size > 1
        names = unknown.map(&:inspect).join(", ")
        raise ArgumentError, "unknown keyword#{plural}: #{names}"
      end
      private_class_method :reject_unknown
    end
  end
end
