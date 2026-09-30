module Hecks
  # A named registry of "canonical IR in, external artifact out" tools, each
  # taking one bluebook's IR and answering a derived artifact (`:ir`, `:docs`, ...).
  #
  #   Projector.call(:ir, bluebook: chapter)
  #
  # A projection is inert and derived from a chapter's declaration. An export
  # (rust crate, WASM, CloudFormation) also needs `.world` bindings and declares
  # `needs_world: true`. State projections (`hecks project_expression_tables`) and
  # `Ports::Projection` read-model catch-up are different things and not registered.
  module Projector
    class UnknownProjector < StandardError; end
    # A chapter-scoped projector was handed something that is not a chapter.
    class WrongConstruct < StandardError; end

    module_function

    # Adds `projector` to the registry under `name`, replacing anything
    # already registered there (deliberately unguarded, so specs can stub).
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
    # @param name [String, Symbol] the registered projector's key
    # @param bluebook [Bluebook::Behaviour::Chapter, Hecks::IR] the construct to project
    # @param options [Hash] projector-specific options, passed through unchanged
    # @param world [Bluebook::World, nil] bindings an export needs (`needs_world: true`);
    #   merged into `options[:world]`
    # @return [Object] whatever the projector's own `call` returns
    # @raise [UnknownProjector] if no projector is registered under `name`
    # @raise [WrongConstruct] if `bluebook` lacks what the projector requires
    def call(name, bluebook:, options: {}, world: nil)
      projector = registry.fetch(name.to_sym) do
        raise UnknownProjector, "no projector registered for #{name.inspect} — registered: #{registered.sort.inspect}"
      end
      admits!(name, projector, bluebook, world)
      projector.call(bluebook: bluebook, options: world ? options.merge(world: world) : options)
    end

    # Refuses `construct` if it lacks a capability or declared aggregate `projector` requires.
    # One `is_a?` check covers included and extended capabilities alike.
    #
    # @param name [String, Symbol] the projector's registered key, used in the message
    # @param projector [Module, Class, #call] the target; consulted for `projection_requires`,
    #   `projection_declares` and `projection_needs_world?` when it answers them
    # @param construct [Bluebook::Behaviour::Chapter, Hecks::IR] the construct offered
    # @param world [Bluebook::World, nil] the `world:` given to `Projector.call`
    # @return [void]
    # @raise [WrongConstruct] if a required capability or aggregate is missing, or the
    #   projector needs `world:` and `world` is nil
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

    # Resolves a target given as a constant (`Projections::OIDC`) or a bare
    # key (`:oidc`) to the key it is registered under.
    #
    # @param target [String, Symbol, #projection_key] a registered key, or a target
    #   that declared its own key with `Target#projects_as`
    # @return [String, Symbol] the key to call the target under
    def key_for(target)
      return target.projection_key if target.respond_to?(:projection_key) && target.projection_key

      target
    end

    # Writes `artifact` to `out`; a projector itself never touches disk.
    #
    # `as:` comes from the projection's `emits:` declaration, since a file tree
    # and a Hash of strings are the same object to Ruby.
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

    # Writes each `files` entry under `directory`, answering the paths written.
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
# These need only `Naming`, not this file, so they are safe to load from here.
require_relative "projector/docs_projector"
require_relative "projector/narrate_projector"
require_relative "projector/cli_projector"

Hecks::Projector.register(:ir, Hecks::Projector::IRProjector)
Hecks::Projector.register(:docs, Hecks::Projector::DocsProjector)
Hecks::Projector.register(:narrate, Hecks::Projector::NarrateProjector)
Hecks::Projector.register(:cli, Hecks::Projector::CliProjector)

# Targets are required from lib/hecks.rb, not here: each requires this file, so
# requiring them back would close a circular require.
