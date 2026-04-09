# Hecks::DSL::AggregateBuilder::VoTypeResolution
#
# @domain Layout
#
# Enables bare PascalCase constants as type references in DSL blocks.
# Unknown constants resolve to type references so the IR treats them
# as aggregate or value object names. Supports :: chaining for
# cross-domain references: ModelRegistry::AiModel
#
#   aggregate "Pizza" do
#     attribute :topping, Topping            # => "Topping"
#     reference_to Order                     # => "Order"
#     reference_to ModelRegistry::AiModel    # => "ModelRegistry::AiModel"
#   end
#
module Hecks
  module DSL
    class AggregateBuilder

      # A proxy returned by const_missing that supports :: chaining.
      # ModelRegistry returns TypeRef("ModelRegistry"), then
      # ::AiModel calls const_missing on it → TypeRef("ModelRegistry::AiModel")
      # A type reference that behaves like a String but supports :: chaining.
      # Uses BasicObject so it doesn't pick up module namespace.
      class TypeRef < Module
        def initialize(name)
          @name = name
        end

        def to_s = @name
        def to_str = @name
        def inspect = @name
        def name = @name
        def ==(other) = @name == other.to_s
        def eql?(other) = @name == other.to_s
        def hash = @name.hash
        def include?(str) = @name.include?(str)
        def split(*args) = @name.split(*args)
        def gsub(*args, &b) = @name.gsub(*args, &b)
        def match?(*args) = @name.match?(*args)
        def start_with?(*args) = @name.start_with?(*args)
        def end_with?(*args) = @name.end_with?(*args)
        def downcase = @name.downcase
        def length = @name.length
        def empty? = @name.empty?

        def const_missing(child)
          TypeRef.new("#{@name}::#{child}")
        end

        def is_a?(klass)
          klass == String || super
        end
      end

      module VoTypeResolution
        def self.with_vo_constants
          saved = begin; Object.method(:const_missing); rescue NameError; nil; end
          Object.define_singleton_method(:const_missing) do |name|
            if Thread.current[:_hecks_vo_eval]
              TypeRef.new(name.to_s)
            elsif saved
              saved.call(name)
            else
              super(name)
            end
          end
          Thread.current[:_hecks_vo_eval] = true
          yield
        ensure
          Thread.current[:_hecks_vo_eval] = false
          if saved
            Object.define_singleton_method(:const_missing, saved)
          else
            class << Object; remove_method :const_missing; end rescue nil
          end
        end
      end
    end
  end
end
