module Hecksagain
  module Bluebook
    module DSL
      class HecksagonBuilder
        class << self
          attr_accessor :collector
        end

        attr_reader :binds

        def initialize(domain)
          @domain = domain
          @binds  = []
        end

        def build = IR::Hecksagon.new(domain: @domain, binds: @binds)

        def self.build(domain, &block)
          builder  = new(domain)
          resolver = ->(name) { BindingProxy.namespace(name, builder.binds) }

          previous       = collector
          self.collector = builder.binds
          begin
            ConstShim.with(resolver) { builder.instance_eval(&block) } if block
          ensure
            self.collector = previous
          end

          builder.build
        end
      end
    end
  end
end
