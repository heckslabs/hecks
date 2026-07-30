module Hecksagain
  module Bluebook
    module IR
      class Attribute
        attr_reader :name, :type, :default

        # A Reference is kept AS ITSELF. Every other type is still a name, and
        # crosses over as its construct does.
        def initialize(name:, type:, list: false, default: nil)
          @name    = name.to_sym
          @type    = type.is_a?(Reference) ? type : type.to_s
          @list    = list
          @default = default
        end

        def list?   = @list
        def scalar? = !@list
        def reference? = @type.is_a?(Reference)

        # Held because a declared vocabulary pins it — spec/vocabulary_conformance
        # holds `Primitive`'s members to this list. The `primitive?` predicate that
        # used to read it had no caller anywhere and is gone.
        PRIMITIVES = %w[String Integer Float TrueClass FalseClass].freeze

        # `type` is spelled, never handed over. A Reference renders as
        # "Reference<Customer>" here because that is what the Rust parser reads.
        def to_h
          { name: @name, type: @type.to_s, list: @list, default: @default }
        end
      end
    end
  end
end
