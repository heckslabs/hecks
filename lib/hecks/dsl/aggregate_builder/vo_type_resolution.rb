# Hecks::DSL::AggregateBuilder::VoTypeResolution
#
# @domain Layout
#
# Enables bare PascalCase constants as type references in DSL blocks.
# Unknown constants resolve to anonymous Modules that chain via
# const_missing for cross-domain :: references.
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
      module VoTypeResolution
        def self.with_vo_constants
          saved = begin; Object.method(:const_missing); rescue NameError; nil; end
          Object.define_singleton_method(:const_missing) do |name|
            if Thread.current[:_hecks_vo_eval]
              qualified = name.to_s
              mod = Module.new
              mod.define_singleton_method(:const_missing) do |child|
                child_mod = Module.new
                full = "#{qualified}::#{child}"
                child_mod.define_singleton_method(:to_s) { full }
                child_mod.define_singleton_method(:to_str) { full }
                child_mod.define_singleton_method(:name) { full }
                child_mod.define_singleton_method(:inspect) { full }
                child_mod
              end
              mod.define_singleton_method(:to_s) { qualified }
              mod.define_singleton_method(:to_str) { qualified }
              mod.define_singleton_method(:name) { qualified }
              mod.define_singleton_method(:inspect) { qualified }
              mod
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
