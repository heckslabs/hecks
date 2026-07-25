# TypeName — a domain type referenced in a bluebook before it exists as a class.
#
# `attribute :toppings, list_of(Topping)` names Topping while nothing called
# Topping is defined yet. During a DSL load the loader installs a const_missing
# shim that hands back one of these instead of raising, so the bluebook reads as
# domain language rather than as symbols-quoting-types.
#
# Real Ruby classes (String, Integer) resolve normally and never reach here.
#
#   TypeName.new(:Topping).to_s  # => "Topping"
module Hecksagain
  module IR
    class TypeName
      attr_reader :name

      def initialize(name)
        @name = name.to_s
      end

      def to_s = @name
      def to_sym = @name.to_sym
      def inspect = "#<TypeName #{@name}>"
      def ==(other) = other.to_s == @name
      alias eql? ==
      def hash = @name.hash
    end
  end
end
