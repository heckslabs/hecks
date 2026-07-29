module Hecksagain
  module Bluebook
    module DSL
      module AttributeCollector
        ListOf = Struct.new(:type)

        def attributes = @attributes ||= []

        def attribute(name, type = String, default: nil)
          # moved to the language: FieldName invariant, on Root.Attribute

          list = type.is_a?(ListOf)
          attributes << IR::Attribute.new(
            name:    name,
            type:    list ? type.type : type,
            list:    list,
            default: default
          )
        end

        def list_of(type) = ListOf.new(type)
      end
    end
  end
end
