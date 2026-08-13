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
  # THREE KINDS OF "PROJECT", TOLD APART BY WHAT THEY NEED AS INPUT.
  # Only the first belongs in this registry.
  #
  #   A PROJECTION takes a chapter's DECLARATION and answers something
  #   that DESCRIBES the domain: its IR, its storage shape, an OIDC scope
  #   manifest, the parser's keyword table, the reference pages. Inert,
  #   derived, and runnable against any chapter that carries what it
  #   declares it needs. These are what `register` holds.
  #
  #   AN EXPORT takes a declaration AND its BINDINGS and answers
  #   something that IS the domain, running elsewhere — rust/project.rb's
  #   generated crate, the WASM artifact, the SAM template
  #   bin/project_deploy renders. It needs the `.world`/`.hecksagon` a
  #   projection never looks at, because a running system has to know how
  #   it is wired. That is the whole reason bin/project_deploy cannot use
  #   this protocol: `call(bluebook:, options:)` has no channel for it.
  #
  #   A STATE PROJECTION takes RECORDS — a domain after dispatch — and is
  #   a read-model question wearing the same word.
  #   `bin/expression_projection` is the one of these: its operators are
  #   not declared anywhere, they are what exists after
  #   `Grammar.expression` replays expression_operators.json's ledger of
  #   dispatches. Converting it into this registry would be a category
  #   error, however much its name suggests otherwise.
  #
  # ONE WORD, THREE OTHER MEANINGS — worth naming too, because grepping
  # "projection" turns all of these up and none is the above:
  #
  #   Ports::Projection    read-model catch-up, events folded into state
  #   bin/project          forces that catch-up by hand
  #   RustProjection       rust/project.rb's own separate toolchain
  module Projector
    class UnknownProjector < StandardError; end
    # A chapter-scoped projector was handed something that is not a chapter.
    class WrongConstruct < StandardError; end

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

    # `bluebook:` is kept as the keyword because it is the shipped
    # spelling and every existing caller uses it — but what it accepts is
    # any construct that emits IR, and `admits!` is what decides whether
    # THIS target can actually take the one handed over.
    def call(name, bluebook:, options: {})
      projector = registry.fetch(name.to_sym) {
        raise UnknownProjector, "no projector registered for #{name.inspect} — registered: #{registered.sort.inspect}"
      }
      admits!(name, projector, bluebook)
      projector.call(bluebook: bluebook, options: options)
    end

    # A projection names the CAPABILITIES it needs; this refuses a
    # construct that lacks one, before the projector runs.
    #
    # ONE CHECK COVERS BOTH SHAPES. An ordinary construct INCLUDES its
    # capabilities and a class-shaped one — Command, Entity, ValueObject
    # — EXTENDS them, and `is_a?` consults the singleton chain, so it
    # answers for an extended module as readily as an included one. This
    # started as two checks on the assumption it would not; a spec
    # asserting the assumption failed, which is the only reason the
    # redundant half was noticed.
    def admits!(name, projector, construct)
      needed = projector.respond_to?(:projection_requires) ? projector.projection_requires : []
      missing = needed.reject { |capability| capable?(construct, capability) }
      unless missing.empty?
        raise WrongConstruct,
              "#{name.inspect} needs #{missing.map(&:name).join(' and ')}, and was handed " \
              "#{construct.class} (#{construct.respond_to?(:hecks_name) ? construct.hecks_name : construct.inspect})."
      end

      declared = projector.respond_to?(:projection_declares) ? projector.projection_declares : []
      absent   = declared.reject { |named| construct.aggregate(named) }
      return if absent.empty?

      raise WrongConstruct,
            "#{name.inspect} needs a chapter declaring #{absent.join(' and ')}; " \
            "#{construct.name} declares no such aggregate."
    end

    def capable?(construct, capability) = construct.is_a?(capability)

    # What KIND of artifact a registered target emits — asked of the
    # projection rather than inferred from what it returned.
    def emits_for(name)
      projector = registry.fetch(name.to_sym) { return :artifact }
      projector.respond_to?(:projection_emits) ? projector.projection_emits : :artifact
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
    # `as:` comes from the projection's own `emits:` declaration rather
    # than from inspecting the artifact. A Hash of path => contents and a
    # Hash that simply happens to hold strings are the same object to
    # Ruby; only the projection knows which it meant.
    def write(artifact, out, as: :artifact)
      return write_tree(artifact, out) if as == :files

      File.write(out, artifact.is_a?(String) ? artifact : "#{JSON.pretty_generate(artifact)}\n")
      out
    end

    # Answers the paths written, in the order given — so a caller can
    # report what happened without re-deriving it from the tree.
    def write_tree(files, directory)
      require "fileutils"
      files.map do |relative, contents|
        path = File.join(directory, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, contents)
        path
      end
    end

  end
end

require "json"

require_relative "projector/exporter"
require_relative "projector/ir_projector"
require_relative "projector/target"
# Neither of these requires this file back — they need `Naming` and nothing
# else — so unlike a target they are safe to pull in from here.
require_relative "projector/docs_projector"
require_relative "projector/cli_projector"

Hecksagain::Projector.register(:ir, Hecksagain::Projector::IRProjector)
Hecksagain::Projector.register(:docs, Hecksagain::Projector::DocsProjector)
Hecksagain::Projector.register(:cli, Hecksagain::Projector::CliProjector)

# The TARGETS are required from lib/hecksagain.rb, immediately after this
# file — deliberately not from here. A target requires this file (it
# needs `Target` and the registry), so requiring them back from here
# would close a genuine `circular require considered harmful` loop. Ruby
# tolerates it; the warning is still right, and load order is the kind of
# thing that only breaks once someone requires a target on its own.
