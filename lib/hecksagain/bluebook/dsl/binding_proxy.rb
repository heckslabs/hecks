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
