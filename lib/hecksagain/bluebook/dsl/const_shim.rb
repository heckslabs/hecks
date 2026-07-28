module Hecksagain
  module Bluebook
    module DSL
      module ConstShim
        class << self
          attr_accessor :resolver

          def with(resolver)
            previous  = @resolver
            @resolver = resolver
            yield
          ensure
            @resolver = previous
          end

          def active? = !@resolver.nil?
        end

        module Hook
          def const_missing(name)
            resolver = ConstShim.resolver
            resolver ? resolver.call(name) : super
          end
        end
      end
    end
  end
end

Object.singleton_class.prepend(Hecksagain::Bluebook::DSL::ConstShim::Hook)
