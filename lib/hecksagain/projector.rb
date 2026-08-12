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
  # ONE WORD, THREE MEANINGS — worth naming, because grepping "projection"
  # in this codebase turns up all three and they are unrelated:
  #
  #   Projector (here)     canonical IR in, external artifact out
  #   Ports::Projection    read-model catch-up, events folded into view state
  #   RustProjection       rust/project.rb's own separate toolchain
  #
  # `bin/project` belongs to the SECOND one (it forces read-model
  # catch-up by hand), which is why the domain-facing verb added for this
  # module lives on the domain itself — `Pizzas.project(Projections::OIDC)`
  # — rather than as another bin/ script that would collide with it.
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

    # A target may be addressed by the constant that implements it
    # (`Projections::OIDC`) or by the bare key it registered under
    # (`:oidc`). Both resolve here, so the constant form is added
    # surface rather than a replacement — every `Projector.call(:ir, ...)`
    # written before this existed keeps working untouched.
    def key_for(target)
      return target.projection_key if target.respond_to?(:projection_key) && target.projection_key

      target
    end

    # WRITING IS THE CALLER'S CHOICE, NOT THE PROJECTOR'S. A projector
    # returns an artifact and never touches disk, which is what lets
    # spec/projector_spec.rb compare `:ir`'s output against a golden
    # fixture without a tmpdir. `out:` is the only thing that writes.
    #
    # Deliberately NOT handling the file-TREE case (a Hash of path =>
    # contents, what a Rust or docs projector would want). Sniffing one
    # from an ordinary Hash is guesswork — `{"name" => "Pizzas"}` is
    # indistinguishable from a one-file tree — and no registered target
    # emits one yet. When Rust is retrofitted it should declare its
    # output kind explicitly rather than have this method infer it.
    def write(artifact, out)
      contents = artifact.is_a?(String) ? artifact : "#{JSON.pretty_generate(artifact)}\n"
      File.write(out, contents)
      out
    end
  end
end

require "json"

require_relative "projector/exporter"
require_relative "projector/ir_projector"
require_relative "projector/target"

Hecksagain::Projector.register(:ir, Hecksagain::Projector::IRProjector)

# The TARGETS are required from lib/hecksagain.rb, immediately after this
# file — deliberately not from here. A target requires this file (it
# needs `Target` and the registry), so requiring them back from here
# would close a genuine `circular require considered harmful` loop. Ruby
# tolerates it; the warning is still right, and load order is the kind of
# thing that only breaks once someone requires a target on its own.
