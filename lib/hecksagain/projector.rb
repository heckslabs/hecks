module Hecksagain
  # A named registry of "canonical IR in, external artifact out" tools —
  # §30 of docs/HECKS_IMPLEMENTATION_PLAN.md. Before this existed, every
  # such tool was its own thing with its own call shape: `Exporter`
  # (registry-wide, consumed directly by bin/ir, bin/project_rust, and
  # translation/audit's approval digest — untouched by this file, still
  # exactly what those three read), and `RustProjection::Projector`
  # (`rust/project.rb`, a whole separate Ruby program under a
  # confusingly-identical module name) are the two that already exist.
  # Neither is registered here — retrofitting either is real, separate
  # work (Rust's generator is a whole second toolchain; a UL/OIDC
  # projector doesn't exist yet at all) — but `:ir` is, as a genuine,
  # working, golden-tested example of the shape every future projector
  # (`:rust`, `:ul`, `:openid`, ...) is meant to follow.
  #
  # The unit is ONE bluebook's IR, not a whole booted registry — matching
  # every real projection target (Rust/UL/OIDC all project one domain at
  # a time), and deliberately narrower than `Exporter.call`'s own
  # multi-domain shape.
  module Projector
    class UnknownProjector < StandardError; end

    module_function

    # `projector` needs only to answer `call(bluebook:, options:)` — a
    # module, a class with a class method, or any object responding to
    # `call` all work. Re-registering a name replaces it outright,
    # deliberately unguarded: a spec re-registering a stub under the same
    # name between examples is the ordinary case, not a footgun to fence
    # against.
    def register(name, projector)
      registry[name.to_sym] = projector
    end

    def call(name, bluebook:, options: {})
      registry.fetch(name.to_sym) {
        raise UnknownProjector, "no projector registered for #{name.inspect} — registered: #{registered.sort.inspect}"
      }.call(bluebook: bluebook, options: options)
    end

    def registered?(name) = registry.key?(name.to_sym)
    def registered = registry.keys

    def registry
      @registry ||= {}
    end
  end
end

require_relative "projector/exporter"
require_relative "projector/ir_projector"

Hecksagain::Projector.register(:ir, Hecksagain::Projector::IRProjector)
