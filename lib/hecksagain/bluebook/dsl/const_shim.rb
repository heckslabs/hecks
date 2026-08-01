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

        # A SCOPED NAME IS WRITTEN AS TEXT, NOT AS A CONSTANT PATH — see the
        # note on `admits:` in AttributeCollector. A resolver returning a
        # Module (so that `Vocabulary::QueryComparator` reaches a second
        # `const_missing`) was tried and cannot be made to hold : `Facade::
        # Surface` installs EVERY aggregate name as a top-level constant, so
        # once any facade is built, `Vocabulary` resolves to that real module
        # and never reaches this hook at all. A spelling that works only
        # before a facade exists is worse than one that always works.
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
