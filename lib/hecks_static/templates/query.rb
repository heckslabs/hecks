# __DOMAIN_MODULE__::Runtime::Query
#
# Mixin for query classes. Provides repository wiring and delegates
# query methods (where, order, limit, etc.) to a QueryBuilder.

module __DOMAIN_MODULE__
  module Runtime
    module Query
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        attr_accessor :repository

        def call(*args)
          instance = new
          instance.send(:with_builder, *args)
        end
      end

      private

      def with_builder(*args)
        @builder = QueryBuilder.new(self.class.repository)
        result = call(*args)
        result.is_a?(QueryBuilder) ? result : @builder
      end

      def where(**conditions)
        @builder = @builder.where(**conditions)
      end

      def order(key)
        @builder = @builder.order(key)
      end

      def limit(n)
        @builder = @builder.limit(n)
      end

      def offset(n)
        @builder = @builder.offset(n)
      end

      def gt(value)     = Operators::Gt.new(value)
      def gte(value)    = Operators::Gte.new(value)
      def lt(value)     = Operators::Lt.new(value)
      def lte(value)    = Operators::Lte.new(value)
      def not_eq(value) = Operators::NotEq.new(value)
      def one_of(values) = Operators::In.new(values)
    end
  end
end
