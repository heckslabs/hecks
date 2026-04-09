module Hecks
  module DSL
    class AggregateBuilder

      # Hecks::DSL::AggregateBuilder::VoTypeResolution
      #
      # Enables bare PascalCase constants as attribute types in DSL blocks by
      # temporarily intercepting Object.const_missing during instance_eval.
      # Unknown constants resolve to their string name so the IR treats them
      # as value object references.
      #
      #   aggregate "Pizza" do
      #     value_object "Topping" do
      #       attribute :name, String
      #     end
      #     attribute :topping, Topping   # resolves to "Topping"
      #   end
      #
      # Follows the same thread-local guard pattern used by
      # Hecks::Bluebook::BuilderMethods#with_annotation_constants.
      module VoTypeResolution
        # Wrap a block eval so that unresolved PascalCase constants become
        # strings instead of raising NameError.
        #
        # @yield the DSL block to evaluate
        # @return [Object] the block's return value
        def self.with_vo_constants
          saved = begin; Object.method(:const_missing); rescue NameError; nil; end
          Object.define_singleton_method(:const_missing) do |name|
            if Thread.current[:_hecks_vo_eval]
              name.to_s
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
