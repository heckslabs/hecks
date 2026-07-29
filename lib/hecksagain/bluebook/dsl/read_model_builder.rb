module Hecksagain
  module Bluebook
    module DSL
      class ReadModelBuilder
        include QuerySpecification::Common::DSL

        def initialize(name)
          @name = name
        end

        def description(value)
          # moved to the language: ProjectionText / purpose, on Projection.Declare
          @description = value
        end

        def use_index(name)
          @index_hints ||= []
          @index_hints << QuerySpecification::Common::IndexHint.new(name: name)
        end

        def reference_to(type, as: nil)
          raise Malformed, "#{@name} already has a projection reference" if @reference_target
          @reference_target = Naming.demodulise(type)
          @reference_name   = (as || Naming.snake(@reference_target)).to_sym
        end

        def include(type, as: nil)
          # NOT portable : this is a rule about the ORDER DSL calls are made, and a
          # built IR carries no ordering — the judge always declares before it
          # gathers, so the language cannot see the violation. Same category as
          # one_of-without-a-block : DSL-level, never reaches the IR.
          raise Malformed, "#{@name} declares includes before its aggregate-head reference" unless @reference_target

          target = Naming.demodulise(type)
          add_aggregate_head(target, as, many: target != @reference_target)
        end

        def build
          raise Malformed, "#{@name} needs an aggregate-head reference" unless @reference_target
          IR::ReadModel.new(name: @name, description: @description, reference_name: @reference_name,
                            reference_target: @reference_target, aggregate_heads: @aggregate_heads || [],
                            wheres: @wheres || [], order_by: @order_by, limit: @limit, offset: @offset,
                            cursor: @cursor, consistency: @consistency, freshness: @freshness,
                            authorization: @authorization, null_semantics: @null_semantics,
                            inspection: @inspection,
                            index_hints: @index_hints || [])
        end

        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end

        def add_aggregate_head(type, name, many:)
          @aggregate_heads ||= []
          target = Naming.demodulise(type)
          output = (name || (many ? "#{Naming.snake(target)}s" : Naming.snake(target))).to_sym
          raise Malformed, "#{@name} already projects #{output}" if @aggregate_heads.any? { |head| head[:as] == output }

          @aggregate_heads << { aggregate: target, as: output, many: many }
        end
      end
    end
  end
end
