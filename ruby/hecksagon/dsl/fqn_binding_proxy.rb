# Hecksagon::DSL::FqnBindingProxy
#
# Resolves the FQN port-verb BIND surface in a .hecksagon block so the legacy
# Ruby HecksagonBuilder parses it byte-equal to the Rust parser. The bind line
#
#   Pizzas::Order.charged_by("Stripe", on: "OrderPlaced") do
#     success "Order.Authorize"
#     failure "Order.Decline"
#   end
#
# is evaluated as Ruby : `Pizzas` hits const_missing, `::Order` chains, and
# `.charged_by(...)` records a binding. Because Ruby's `::` REQUIRES a Module on
# the left, each segment must be a real anonymous Module (a bare object cannot be
# `::`-chained — that is the very error this fixes : `AnnotationSelector ... is
# not a class/module`).
#
# Two grammars share the first PascalCase const :
#   * `Head::Agg.verb(...)`  (a `::` appeared)  → a BIND, recorded into `bindings`
#   * `Head.attr.annotation` (dots only)        → the existing ANNOTATION chain,
#                                                  delegated to AnnotationSelector
# Annotations are Ruby-only (outside the canonical parity shape) ; bindings are
# the parity-relevant output. Field extraction mirrors
# rust/src/hecksagon_parser.rs :: parse_binding exactly :
#   aggregate = the `::`-qualified head, verb = the method, adapter = first
#   quoted arg, on = the `on:` kwarg ("" if absent), success/failure = the
#   verdict block lines ("" if no block).
module Hecksagon
  module DSL
    module FqnBindingProxy
      module_function

      # The FIRST const in a block (no `::` yet). Dots delegate to the annotation
      # grammar ; `::` switches into a binding proxy.
      def head(name, annotations, bindings)
        mod = Module.new
        mod.define_singleton_method(:const_missing) do |child|
          FqnBindingProxy.binding_proxy("#{name}::#{child}", bindings)
        end
        mod.define_singleton_method(:method_missing) do |m, *args, **opts, &blk|
          # No `::` was used — this is the legacy annotation chain. Delegate to a
          # real AnnotationSelector so existing files behave exactly as before.
          AnnotationSelector.new(annotations, name).__send__(m, *args, **opts, &blk)
        end
        FqnBindingProxy.stamp(mod, name)
        mod
      end

      # A `::`-reached node : `.verb(...)` records a bind ; a deeper `::` keeps
      # qualifying (A::B::C).
      def binding_proxy(qualified, bindings)
        mod = Module.new
        mod.define_singleton_method(:const_missing) do |child|
          FqnBindingProxy.binding_proxy("#{qualified}::#{child}", bindings)
        end
        mod.define_singleton_method(:method_missing) do |verb, *args, **opts, &block|
          adapter = args.first.to_s
          on      = opts.key?(:on) ? opts[:on].to_s : ""
          success = ""
          failure = ""
          if block
            collector = BindingBlockCollector.new
            collector.instance_eval(&block)
            success, failure = collector.result
          end
          bindings << {
            aggregate: qualified, verb: verb.to_s, adapter: adapter,
            on: on, success: success, failure: failure
          }
          mod
        end
        FqnBindingProxy.stamp(mod, qualified)
        mod
      end

      # Make the anonymous module print as its qualified name (matches the VO
      # const proxy convention) and answer respond_to? for any verb.
      def stamp(mod, label)
        mod.define_singleton_method(:to_s)   { label }
        mod.define_singleton_method(:to_str) { label }
        mod.define_singleton_method(:name)   { label }
        mod.define_singleton_method(:inspect) { label }
        mod.define_singleton_method(:respond_to_missing?) { |*| true }
      end
    end

    # Captures the effect-port verdict block `do success "..." failure "..." end`.
    # Unknown verdict keys are tolerated (return self) so the block never raises —
    # the Rust parser likewise reads only the success/failure lines.
    class BindingBlockCollector
      def initialize
        @success = ""
        @failure = ""
      end

      def success(value)
        @success = value.to_s
      end

      def failure(value)
        @failure = value.to_s
      end

      def result
        [@success, @failure]
      end

      def method_missing(*)
        self
      end

      def respond_to_missing?(*)
        true
      end
    end
  end
end
