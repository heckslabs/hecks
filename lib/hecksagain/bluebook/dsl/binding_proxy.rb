module Hecksagain
  module Bluebook
    module DSL
      class BindingProxy
        def self.namespace(domain, collector)
          Module.new do
            define_singleton_method(:const_missing) do |aggregate|
              BindingProxy.new("#{domain}::#{aggregate}", collector)
            end
          end
        end

        def initialize(fqn, collector)
          @fqn       = fqn
          @collector = collector
        end

        # THE AGGREGATE-SCOPED PORT — `Payments::Payment.port("Gateway") do
        # ... end`, the same receiver a plain bind like `.persisted_by(...)`
        # already reaches, because a port belongs to exactly one aggregate
        # the same way a bind does. A REAL method, not method_missing : its
        # shape (a name and a block building operations) has nothing to do
        # with `IR::Bind`, so it does not belong in that generic verb path.
        def port(name, &block)
          domain, aggregate_name = @fqn.split("::")
          aggregate_ir = Hecksagain.current_registry.bluebook(domain)&.aggregate(aggregate_name) or
            raise Malformed, "#{@fqn} declares no such aggregate — a port needs one to belong to"

          # See HecksagonBuilder#port's own comment on why this resolver
          # swap is needed : ConstShim's active resolver is one global for
          # the whole dynamic extent, and it is currently this file's own
          # BindingProxy-minting one, which would turn a bare `Pizza` inside
          # `reference_to Pizza` into another BindingProxy instead of a name.
          domain_port = ConstShim.with(->(const) { const }) { DomainPortBuilder.build(name, owner: aggregate_name, &block) }
          domain_port.operations.each do |operation|
            operation.attributes.select(&:reference?).each { |attribute| attribute.type.declared_in = aggregate_ir }
          end
          aggregate_ir.add_port(domain_port)
          self
        end

        def method_missing(verb, *args, **kwargs, &block)
          @collector << IR::Bind.new(
            aggregate: @fqn,
            verb:      verb.to_s,
            adapter:   args.first.to_s,
            role:      kwargs[:role]&.to_s
          )
          block&.call
          self
        end

        def respond_to_missing?(_name, _include_private = false) = true

        def to_s = @fqn
      end
    end
  end
end
