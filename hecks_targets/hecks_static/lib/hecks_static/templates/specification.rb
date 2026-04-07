# __DOMAIN_MODULE__::Runtime::Specification
#
# Mixin for specification classes. Specifications are reusable, composable
# predicate objects that encapsulate business rules. Supports boolean
# composition via and/or/not operators.

module __DOMAIN_MODULE__
  module Runtime
    module Specification
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def satisfied_by?(object)
          new.satisfied_by?(object)
        end
      end

      def satisfied_by?(_object)
        raise NotImplementedError, "#{self.class}#satisfied_by? must be implemented"
      end

      def and(other)
        AndSpecification.new(self, other)
      end

      def or(other)
        OrSpecification.new(self, other)
      end

      def not
        NotSpecification.new(self)
      end

      class AndSpecification
        include Specification
        def initialize(left, right)
          @left = left
          @right = right
        end
        def satisfied_by?(object)
          @left.satisfied_by?(object) && @right.satisfied_by?(object)
        end
      end

      class OrSpecification
        include Specification
        def initialize(left, right)
          @left = left
          @right = right
        end
        def satisfied_by?(object)
          @left.satisfied_by?(object) || @right.satisfied_by?(object)
        end
      end

      class NotSpecification
        include Specification
        def initialize(spec)
          @spec = spec
        end
        def satisfied_by?(object)
          !@spec.satisfied_by?(object)
        end
      end
    end
  end
end
