require "hecks"
require "hecks/bluebook/model_check"
require "hecks/runtime/capability_graph"
require_relative "board"

module Hecks
  module Composer
    # Judges a workspace as it stands on screen: parse it, boot it, then draw and read back what
    # it declares. It changes nothing on disk and holds nothing between calls, so a caller may
    # run it on every pause in typing.
    module Check
      module_function

      # @param dir [String] the workspace directory
      # @param buffers [Hash{String => String}] unsaved text by path relative to `dir`
      # @param declaration_name [String, nil] the bluebook to draw; the first bluebook's when nil
      # @return [Hash] `diagnostic` (nil, or `{file:, line:, message:, expected:}` for the first
      #   refusal), `files` (the workspace's declaration files), `outline` (see {Outline}),
      #   `bluebook` (the name drawn), `diagrams` (Mermaid text by file name), `statements` (plain
      #   sentences), `findings` (`{kind:, severity:, subject:, message:}` per model-check
      #   finding), `wiring` (see {wiring}, nil until the workspace boots), `board` (the
      #   event-storming notes, see {Board}, nil until it boots) and `elapsed_ms`
      def call(dir:, buffers: {}, declaration_name: nil)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = Workspace.stage(dir: dir, buffers: buffers) { |stage| judge(stage, declaration_name) }
        result.merge(elapsed_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
      end

      # @api private
      def judge(stage, declaration_name)
        files = Workspace.files(stage)
        verdict(stage, empty(files, Outline.call(stage, files)), declaration_name)
      end

      # What the parser and the boot say of the staged text, laid over `base`.
      # @api private
      def verdict(stage, base, declaration_name)
        refusal = Parse.call(stage)
        return base.merge(diagnostic: refusal) if refusal

        project(stage, base, declaration_name || Parse.bluebooks(stage).keys.first)
      rescue Parse::ParserMissing
        raise
      rescue StandardError => e
        base.merge(diagnostic: { file: nil, line: nil, message: Text.headline(e.message), expected: [] })
      end

      # @api private
      def project(stage, base, name)
        registry = Hecks.boot(stage, install_driving: false, environment: "memory").registry
        declaration = registry.bluebook(name)
        base.merge(bluebook: name, wiring: wiring(registry, name),
                   board: Board.call(declaration, outline: base[:outline]), **read(declaration, registry.hecksagon(name)))
      end

      # The diagrams, statements and model-check findings of a booted bluebook.
      # @api private
      def read(declaration, hecksagon)
        { diagrams:   Projections::Diagrams.call(bluebook: declaration, options: { hecksagon: hecksagon }),
          statements: Projections::Statements.call(bluebook: declaration),
          findings:   Bluebook::ModelCheck.call(declaration, hecksagon: hecksagon).map(&:to_h) }
      end

      # What the bluebook is wired to: the binds its hecksagon declares, the bluebooks it attaches,
      # the driving adapters it admits, the world's default adapter, and each declared port with
      # the adapters bound to it.
      #
      # @param registry [Runtime::Registry] a booted registry
      # @param name [String] the bluebook's name
      # @return [Hash] `binds`, `attaches`, `driving`, `default_adapter` and `ports`
      def wiring(registry, name)
        hecksagon = registry.hecksagon(name)
        {
          binds:           (hecksagon&.binds || []).map { |bind| bind.to_h.slice(:aggregate, :verb, :adapter, :role) },
          attaches:        hecksagon&.member_bluebooks || [],
          driving:         hecksagon&.driving || [],
          default_adapter: registry.world(name)&.default_adapter,
          ports:           Runtime::CapabilityGraph.new(registry).fulfillments
        }
      end

      # @api private
      def empty(files, outline)
        { diagnostic: nil, files: files, outline: outline, bluebook: nil, diagrams: {},
          statements: [], findings: [], wiring: nil, board: nil }
      end
    end
  end
end
