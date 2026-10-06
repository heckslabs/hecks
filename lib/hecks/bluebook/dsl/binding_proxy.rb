module Hecks
  module Bluebook
    module DSL
      # What a bare `Domain::Aggregate` constant resolves to inside a `.hecksagon`/`.world`
      # block; `method_missing` records a bind, `#port` is the one real method on this proxy.
      class BindingProxy
        # Mints the module a bare `Domain::Aggregate` constant resolves to via `const_missing`.
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

        # Declares a port on this aggregate. A real method, not method_missing — its
        # shape (name plus an operations block) is unrelated to `Bind`'s generic verb path.
        def port(name, &block)
          domain, aggregate_name = @fqn.split("::")
          aggregate_ir = Hecks.current_registry.bluebook(domain)&.aggregate(aggregate_name) or
            raise Malformed, "#{@fqn} declares no such aggregate — a port needs one to belong to"

          register_port(build_port(name, aggregate_name, block), aggregate_ir)
          self
        end

        def method_missing(verb, *args, **kwargs, &block)
          # A bare call (no args/kwargs/block) starts a Privacy marking chain instead
          # of a Bind — no real `.hecksagon` bind is ever called with zero arguments,
          # so this can't collide with recording one.
          return AttributePath.new(@fqn, [verb.to_s]) if args.empty? && kwargs.empty? && !block

          @collector << Bind.new(
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

        private

        # ConstShim's resolver is one global for the whole dynamic extent; without
        # swapping it here, a bare `Pizza` inside `reference_to Pizza` would resolve
        # to another BindingProxy instead of a plain name.
        def build_port(name, aggregate_name, body)
          ConstShim.with(->(const) { const }) { DomainPortBuilder.build(name, owner: aggregate_name, &body) }
        end

        # A `verb`-shaped port is a plain `Port`, the same struct `Hecks.port`
        # registers — it belongs to no aggregate IR the way an operations-shaped
        # `DomainPort` does, so it takes the registry's `add_port` directly.
        def register_port(built, aggregate_ir)
          return Hecks.current_registry.add_port(built) if built.is_a?(Port)

          built.operations.each do |operation|
            operation.attributes.select(&:reference?).each { |attribute| attribute.type.declared_in = aggregate_ir }
          end
          aggregate_ir.add_port(built)
        end
      end

      # What a Privacy-marking chain resolves to after its first bare segment — each
      # bare call extends the path one segment; a terminal `has_<category>(readable_by:)` ends it.
      class AttributePath
        def initialize(fqn, path)
          @fqn  = fqn
          @path = path
        end

        # Records a `has_<category>` marking, or extends the attribute path by one segment.
        def method_missing(verb, *args, readable_by: nil, **kwargs, &block)
          name = verb.to_s
          return record_marking(name.delete_prefix("has_"), readable_by) if name.start_with?("has_")

          if !args.empty? || !kwargs.empty? || block
            raise Malformed, "#{@fqn}.#{@path.join(".")}.#{name} — an attribute path chain takes no " \
                             "arguments except a terminal has_<category>(readable_by:)"
          end

          AttributePath.new(@fqn, @path + [name])
        end

        def respond_to_missing?(_name, _include_private = false) = true

        def to_s = "#{@fqn}.#{@path.join(".")}"

        private

        def record_marking(category, readable_by)
          raise Malformed, "#{self}.has_#{category} needs readable_by: (the Governance role a read must hold)" unless readable_by

          Hecks.current_registry.add_pending_privacy_marking(
            domain: @fqn, attribute_path: @path.join("."), category: category, readable_by: readable_by
          )
          nil
        end
      end
    end
  end
end
