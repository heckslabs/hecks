# __DOMAIN_MODULE__::Runtime::QueryBuilder
#
# Chainable query interface for aggregate repositories. Collects query
# parameters and delegates execution to the adapter's query method,
# falling back to in-memory filtering for complex conditions.

module __DOMAIN_MODULE__
  module Runtime
    class ConditionNode
      attr_reader :type, :children, :conditions

      def self.and(conditions = {})
        new(type: :and, conditions: conditions)
      end

      def self.or(left, right)
        new(type: :or, children: [left, right])
      end

      def initialize(type:, conditions: {}, children: [])
        @type = type
        @conditions = conditions
        @children = children
      end

      def merge(new_conditions)
        if type == :and && children.empty?
          self.class.new(type: :and, conditions: @conditions.merge(new_conditions))
        else
          self.class.new(type: :and, children: [self, self.class.and(new_conditions)])
        end
      end

      def simple?
        type == :and && children.empty?
      end

      def match?(obj)
        case type
        when :and
          cond_match = conditions.all? do |k, v|
            next false unless obj.respond_to?(k)
            actual = obj.send(k)
            v.is_a?(Operators::Operator) ? v.match?(actual) : actual == v
          end
          cond_match && children.all? { |c| c.match?(obj) }
        when :or
          children.any? { |c| c.match?(obj) }
        end
      end
    end

    class QueryBuilder
      include Enumerable

      def initialize(repo)
        @repo = repo
        @condition_tree = ConditionNode.and
        @order_key = nil
        @order_direction = :asc
        @limit_value = nil
        @offset_value = nil
      end

      def where(**conditions)
        dup.tap { |q| q.instance_variable_set(:@condition_tree, q.instance_variable_get(:@condition_tree).merge(conditions)) }
      end

      def or(other)
        dup.tap do |q|
          combined = ConditionNode.or(
            q.instance_variable_get(:@condition_tree),
            other.instance_variable_get(:@condition_tree)
          )
          q.instance_variable_set(:@condition_tree, combined)
        end
      end

      def order(key_or_hash)
        dup.tap do |q|
          if key_or_hash.is_a?(Hash)
            q.instance_variable_set(:@order_key, key_or_hash.keys.first)
            q.instance_variable_set(:@order_direction, key_or_hash.values.first)
          else
            q.instance_variable_set(:@order_key, key_or_hash)
            q.instance_variable_set(:@order_direction, :asc)
          end
        end
      end

      def limit(n)
        dup.tap { |q| q.instance_variable_set(:@limit_value, n) }
      end

      def offset(n)
        dup.tap { |q| q.instance_variable_set(:@offset_value, n) }
      end

      def find_by(**conditions) = where(**conditions).first
      def first   = execute.first
      def last    = execute.last
      def count   = execute.size
      def to_a    = execute
      def each(&block) = execute.each(&block)
      def empty?  = execute.empty?
      def exists? = !execute.empty?
      def size    = count
      alias length size

      def pluck(*keys)
        rows = execute
        keys.size == 1 ? rows.map { |r| r.send(keys.first) } : rows.map { |r| keys.map { |k| r.send(k) } }
      end

      def sum(key)     = execute.map { |r| r.send(key) }.compact.sum
      def min(key)     = execute.map { |r| r.send(key) }.compact.min
      def max(key)     = execute.map { |r| r.send(key) }.compact.max

      def average(key)
        vals = execute.map { |r| r.send(key) }.compact
        vals.empty? ? nil : vals.sum.to_f / vals.size
      end

      def delete_all
        execute.each { |obj| @repo.delete(obj.id) }
      end

      def update_all(**attrs)
        execute.each do |obj|
          init_params = obj.class.instance_method(:initialize).parameters.map { |_, n| n }
          current = init_params.each_with_object({}) { |p, h| h[p] = obj.send(p) if obj.respond_to?(p) }
          @repo.save(obj.class.new(**current.merge(attrs)))
        end
      end

      def gt(value)     = Operators::Gt.new(value)
      def gte(value)    = Operators::Gte.new(value)
      def lt(value)     = Operators::Lt.new(value)
      def lte(value)    = Operators::Lte.new(value)
      def not_eq(value) = Operators::NotEq.new(value)
      def one_of(values) = Operators::In.new(values)

      private

      def execute
        if @condition_tree.simple? && @repo.respond_to?(:query)
          @repo.query(
            conditions: @condition_tree.conditions,
            order_key: @order_key, order_direction: @order_direction,
            limit: @limit_value, offset: @offset_value
          )
        else
          results = @repo.respond_to?(:all) ? @repo.all : []
          results = results.select { |obj| @condition_tree.match?(obj) } unless @condition_tree.conditions.empty? && @condition_tree.children.empty?
          if @order_key
            results = results.sort_by { |obj| v = obj.respond_to?(@order_key) ? obj.send(@order_key) : nil; v.nil? ? "" : v }
            results = results.reverse if @order_direction == :desc
          end
          results = results.drop([@offset_value, 0].max) if @offset_value
          results = results.take([@limit_value, 0].max) if @limit_value
          results
        end
      end
    end
  end
end
