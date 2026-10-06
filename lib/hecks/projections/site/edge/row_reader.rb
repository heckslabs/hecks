# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      class Edge
        # Reads the declared rows of one kind into structs, recording a problem for each unknown
        # field, each missing required field and each field of the wrong type.
        class RowReader
          # @param kind [Symbol] a key of `Edge::OBJECTS`
          # @param problems [Array<String>] collects each problem found
          def initialize(kind, problems)
            @kind = kind
            @problems = problems
            @fields = FIELDS.fetch(kind)
          end

          # @param members [Array<Hash{Symbol => Object}>] the declared rows
          # @return [Array<Struct>] the rows that carry known, well-typed fields
          def call(members)
            members.each_with_index.map { |member, index| read(member, "#{OBJECTS.fetch(@kind)} row #{index + 1}") }
          end

          private

          def read(member, label)
            check_fields(member, label)
            STRUCTS.fetch(@kind).new(**typed_fields(member, label))
          end

          def check_fields(member, label)
            unknown = member.keys - @fields.keys
            @problems << "#{label} has no field #{unknown.join(", ")}; fields are #{@fields.keys.join(", ")}" if unknown.any?
            (REQUIRED.fetch(@kind) - member.keys).each { |field| @problems << "#{label} needs #{field}" }
          end

          # A field of the wrong type is recorded as a problem and kept, so its row still builds.
          def typed_fields(member, label)
            member.slice(*@fields.keys).select do |field, value|
              typed?(value, @fields.fetch(field)) ||
                (@problems << "#{label} has #{field} #{value.inspect}; #{field} is #{type_name(@fields.fetch(field))}")
            end
          end

          def typed?(value, type) = type == :bool ? [true, false].include?(value) : value.is_a?(type)

          def type_name(type) = type == :bool ? "true or false" : "a #{type}"
        end
      end
    end
  end
end
