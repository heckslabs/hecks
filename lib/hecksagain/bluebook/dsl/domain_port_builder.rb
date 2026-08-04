module Hecksagain
  module Bluebook
    module DSL
      class DomainPortBuilder
        def initialize(name, owner: nil)
          @name       = name
          @owner      = owner
          @operations = []
        end

        def operation(name, &block)
          @operations << PortOperationBuilder.build(name, owner: @owner, &block)
        end

        def build
          raise Malformed, "#{@name} declares no operations" if @operations.empty?

          IR::DomainPort.new(name: @name, operations: @operations)
        end

        def self.build(name, owner: nil, &block)
          builder = new(name, owner: owner)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
