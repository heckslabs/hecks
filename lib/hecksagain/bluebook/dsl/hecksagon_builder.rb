module Hecksagain
  module Bluebook
    module DSL
      class HecksagonBuilder
        class << self
          attr_accessor :collector
        end

        attr_reader :binds, :subscriptions

        def initialize(domain)
          @domain        = domain
          @binds         = []
          @subscriptions = []
        end

        # An event this hecksagon takes from OUTSIDE the domain's own
        # bluebook — mirrors rust/src/bluebook/hecksagon_parser.rs's
        # `subscribe` handling, which has read this since before Ruby did.
        def subscribe(event) = @subscriptions << event.to_s

        def build = IR::Hecksagon.new(domain: @domain, binds: @binds, subscriptions: @subscriptions)

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
