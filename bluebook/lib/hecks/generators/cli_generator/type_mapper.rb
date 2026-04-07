# Hecks::Generators::CliGenerator::TypeMapper
#
# Maps Bluebook IR attribute types to Thor option types.
# Thor supports :string, :numeric, :boolean, :array, :hash.
#
#   TypeMapper.thor_type(String)   # => :string
#   TypeMapper.thor_type(Integer)  # => :numeric
#   TypeMapper.thor_type(Float)    # => :numeric
#
module Hecks
  module Generators
    class CliGenerator < Hecks::Generator
      module TypeMapper
        MAPPING = {
          "String"   => :string,
          "Integer"  => :numeric,
          "Float"    => :numeric,
          "Boolean"  => :boolean,
          "Array"    => :array,
          "Hash"     => :hash,
          "JSON"     => :hash,
          "Date"     => :string,
          "DateTime" => :string,
        }.freeze

        # Returns the Thor option type for a given IR attribute type.
        #
        # @param type [Class, String] the IR attribute type
        # @return [Symbol] the Thor option type (:string, :numeric, :boolean, :array, :hash)
        def self.thor_type(type)
          MAPPING.fetch(type.to_s, :string)
        end
      end
    end
  end
end
