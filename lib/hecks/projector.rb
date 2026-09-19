module Hecks
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
  # The unit is one bluebook's IR, not a whole booted registry — matching
  # every real projection target (Rust/UL/OIDC all project one domain at
  # a time), and deliberately narrower than `Exporter.call`'s own
  # multi-domain shape.
  #
  # ## Three kinds of "project"
  #
  # Told apart by what they need as input. Only the first belongs in this
  # registry.
  #
  #   a projection takes a chapter's declaration and answers something
  #   that describes the domain: its IR, its storage shape, an OIDC scope
  #   manifest, the parser's keyword table, the reference pages. Inert,
  #   derived, and runnable against any chapter that carries what it
  #   declares it needs. These are what `register` holds.
  #
  #   an export takes a declaration and its bindings and answers
  #   something that is the domain, running elsewhere — rust/project.rb's
  #   generated crate, the WASM artifact, the CloudFormation template
  #   `lib/hecks/projections/deploy` renders. It needs the
  #   `.world`/`.hecksagon` a projection never looks at, because a
  #   running system has to know how it is wired. A target that needs
  #   this declares `needs_world: true` (`Target#projects_as`) and reads
  #   `options.fetch(:world)`; `Projector.call`'s own `world:` keyword is
  #   what carries it, merged into `options` before the target ever runs.
  #
  #   a state projection takes records — a domain after dispatch — and is
  #   a read-model question wearing the same word.
  #   `bin/expression_projection` is the one of these: its operators are
  #   not declared anywhere, they are what exists after
  #   `Grammar.expression` replays expression_operators.json's ledger of
  #   dispatches. Converting it into this registry would be a category
  #   error, however much its name suggests otherwise.
  #
  # ## One word, three other meanings
  #
  # Worth naming too, because grepping "projection" turns all of these up
  # and none is the above:
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
    # Adds `projector` to the registry under `name`, replacing anything
    # already registered there.
    #
    # @param name [String, Symbol] the key `projector` is looked up by (converted to a symbol)
    # @param projector [Module, Class, #call] anything answering `call(bluebook:, options:)`
    # @return [void]
    def register(name, projector)
      registry[name.to_sym] = projector
    end

    # Runs the projector registered under `name` against `bluebook`,
    # after refusing a construct it does not admit.
    #
    # `bluebook:` is kept as the keyword because it is the shipped
    # spelling and every existing caller uses it — but what it accepts is
    # any construct that emits IR, and `admits!` is what decides whether
    # this target can actually take the one handed over.
    #
    # @param name [String, Symbol] the registered projector's key
    # @param bluebook [Bluebook::Behaviour::Chapter, Hecks::IR] the chapter or
    #   IR-emitting construct to project
    # @param options [Hash] projector-specific options, passed through unchanged
    # @param world [Bluebook::World, nil] the domain's `.world`/`.hecksagon` bindings,
    #   required by an export (`needs_world: true`); nil for an ordinary projection.
    #   Merged into `options[:world]` before the target runs — the target never
    #   receives it as a separate argument.
    # @return [Object] whatever the projector's own `call` returns: typically a
    #   `Hash`/`String` artifact, or a `Hash{String => String}` file tree
    # @raise [UnknownProjector] if no projector is registered under `name`
    # @raise [WrongConstruct] if `bluebook` lacks a capability or aggregate the
    #   projector requires, or if the projector needs `world:` and none is given
    def call(name, bluebook:, options: {}, world: nil)
      projector = registry.fetch(name.to_sym) do
        raise UnknownProjector, "no projector registered for #{name.inspect} — registered: #{registered.sort.inspect}"
      end
      admits!(name, projector, bluebook, world)
      projector.call(bluebook: bluebook, options: world ? options.merge(world: world) : options)
    end

    # Refuses `construct` if it lacks a capability or declared aggregate
    # `projector` requires. A projection names the capabilities it needs;
    # this is what enforces that, before the projector runs.
    #
    # One check covers both shapes. An ordinary construct includes its
    # capabilities and a class-shaped one — Command, Entity, ValueObject
    # — extends them, and `is_a?` consults the singleton chain, so it
    # answers for an extended module as readily as an included one. This
    # started as two checks on the assumption it would not; a spec
    # asserting the assumption failed, which is the only reason the
    # redundant half was noticed.
    #
    # @param name [String, Symbol] the projector's registered key, used in the message
    #   when refusing
    # @param projector [Module, Class, #call] the target being checked; consulted for
    #   `projection_requires`, `projection_declares`, and `projection_needs_world?` when
    #   it answers them
    # @param construct [Bluebook::Behaviour::Chapter, Hecks::IR] the chapter or
    #   IR-emitting construct offered to the projector
    # @param world [Bluebook::World, nil] the `world:` given to `Projector.call`, checked
    #   against the target's own `needs_world:` declaration
    # @return [void]
    # @raise [WrongConstruct] if `construct` lacks a required capability, the chapter it
    #   is declares no aggregate the projector needs, or the projector needs `world:`
    #   and `world` is nil
    def admits!(name, projector, construct, world = nil)
      needed = projector.respond_to?(:projection_requires) ? projector.projection_requires : []
      missing = needed.reject { |capability| capable?(construct, capability) }
      unless missing.empty?
        raise WrongConstruct,
              "#{name.inspect} needs #{missing.map(&:name).join(' and ')}, and was handed " \
              "#{construct.class} (#{construct.respond_to?(:hecks_name) ? construct.hecks_name : construct.inspect})."
      end

      declared = projector.respond_to?(:projection_declares) ? projector.projection_declares : []
      absent   = declared.reject { |named| construct.aggregate(named) }
      unless absent.empty?
        raise WrongConstruct,
              "#{name.inspect} needs a chapter declaring #{absent.join(' and ')}; " \
              "#{construct.name} declares no such aggregate."
      end

      return unless projector.respond_to?(:projection_needs_world?) && projector.projection_needs_world? && world.nil?

      raise WrongConstruct, "#{name.inspect} needs .world/.hecksagon bindings — pass world: to Projector.call."
    end

    # Tells whether `construct` has the capability `admits!` requires of it.
    #
    # @param construct [Bluebook::Behaviour::Chapter, Hecks::IR] the construct to check
    # @param capability [Module] the capability module to check for
    # @return [Boolean] true if `construct` is a `capability`
    def capable?(construct, capability) = construct.is_a?(capability)

    # What kind of artifact a registered target emits — asked of the
    # projection rather than inferred from what it returned.
    #
    # @param name [String, Symbol] the registered projector's key
    # @return [Symbol] `:files` for a path => contents tree, `:artifact` (the
    #   default, including for an unregistered `name`) for a single Hash or String
    def emits_for(name)
      projector = registry.fetch(name.to_sym) { return :artifact }
      projector.respond_to?(:projection_emits) ? projector.projection_emits : :artifact
    end

    # Tells whether a projector is registered under `name`.
    #
    # @param name [String, Symbol] the key to look up
    # @return [Boolean] true if a projector is registered under `name`
    def registered?(name) = registry.key?(name.to_sym)

    # Lists every key currently registered.
    #
    # @return [Array<Symbol>] every key currently registered
    def registered = registry.keys

    # Gives the live registry, initializing it on first use.
    #
    # @return [Hash{Symbol => Module, Class, #call}] the live key => projector registry
    def registry
      @registry ||= {}
    end

    # A target may be addressed by the constant that implements it
    # (`Projections::OIDC`) or by the bare key it registered under
    # (`:oidc`). Both resolve here, so the constant form is added
    # surface rather than a replacement — every `Projector.call(:ir, ...)`
    # written before this existed keeps working untouched.
    #
    # @param target [String, Symbol, #projection_key] a registered key, or a target
    #   that declared its own key with `Target#projects_as`
    # @return [String, Symbol] the key to call the target under
    def key_for(target)
      return target.projection_key if target.respond_to?(:projection_key) && target.projection_key

      target
    end

    # Writing is the caller's choice, not the projector's. A projector
    # returns an artifact and never touches disk, which is what lets
    # spec/projector_spec.rb compare `:ir`'s output against a golden
    # fixture without a tmpdir. `out:` is the only thing that writes.
    #
    # `as:` comes from the projection's own `emits:` declaration rather
    # than from inspecting the artifact. A Hash of path => contents and a
    # Hash that simply happens to hold strings are the same object to
    # Ruby; only the projection knows which it meant.
    #
    # @param artifact [Hash, String] the projector's output; a file tree when `as: :files`
    # @param out [String] the path to write to; a directory when `as: :files`
    # @param as [Symbol] `:files` to write a tree, anything else to write one file
    # @return [String, Array<String>] the path written, or every path written when `as: :files`
    def write(artifact, out, as: :artifact)
      return write_tree(artifact, out) if as == :files

      File.write(out, artifact.is_a?(String) ? artifact : "#{JSON.pretty_generate(artifact)}\n")
      out
    end

    # Answers the paths written, in the order given — so a caller can
    # report what happened without re-deriving it from the tree.
    #
    # @param files [Hash{String => String}] relative path => contents
    # @param directory [String] the directory to write the tree under
    # @return [Array<String>] each file's full written path, in `files`' order
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
require_relative "projector/narrate_projector"
require_relative "projector/cli_projector"

Hecks::Projector.register(:ir, Hecks::Projector::IRProjector)
Hecks::Projector.register(:docs, Hecks::Projector::DocsProjector)
Hecks::Projector.register(:narrate, Hecks::Projector::NarrateProjector)
Hecks::Projector.register(:cli, Hecks::Projector::CliProjector)

# The targets are required from lib/hecks.rb, immediately after this
# file — deliberately not from here. A target requires this file (it
# needs `Target` and the registry), so requiring them back from here
# would close a genuine `circular require considered harmful` loop. Ruby
# tolerates it; the warning is still right, and load order is the kind of
# thing that only breaks once someone requires a target on its own.
