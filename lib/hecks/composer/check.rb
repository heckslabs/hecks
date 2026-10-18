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
      # @param chapter_name [String, nil] the chapter to draw; the first bluebook's when nil
      # @return [Hash] `diagnostic` (nil, or `{file:, line:, message:, expected:}` for the first
      #   refusal), `files` (the workspace's declaration files), `outline` (see {Outline}),
      #   `chapter` (the name drawn), `diagrams` (Mermaid text by file name), `statements` (plain
      #   sentences), `findings` (`{kind:, severity:, subject:, message:}` per model-check
      #   finding), `wiring` (see {wiring}, nil until the workspace boots), `board` (the
      #   event-storming notes, see {Board}, nil until it boots) and `elapsed_ms`
      def call(dir:, buffers: {}, chapter_name: nil)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = Workspace.stage(dir: dir, buffers: buffers) { |stage| judge(stage, chapter_name) }
        result.merge(elapsed_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
      end

      # @api private
      def judge(stage, chapter_name)
        files = Workspace.files(stage)
        verdict(stage, empty(files, Outline.call(stage, files)), chapter_name)
      end

      # What the parser and the boot say of the staged text, laid over `base`.
      # @api private
      def verdict(stage, base, chapter_name)
        refusal = Parse.call(stage)
        return base.merge(diagnostic: refusal) if refusal

        project(stage, base, chapter_name || Parse.bluebooks(stage).keys.first)
      rescue Parse::ParserMissing
        raise
      rescue StandardError => e
        base.merge(diagnostic: { file: nil, line: nil, message: e.message.lines.first.to_s.chomp, expected: [] })
      end

      # @api private
      def project(stage, base, name)
        registry = Hecks.boot(stage, install_driving: false, environment: "memory").registry
        chapter = registry.bluebook(name)
        base.merge(chapter: name, wiring: wiring(registry, name), board: Board.call(chapter, outline: base[:outline]),
                   **read(chapter, registry.hecksagon(name)))
      end

      # The diagrams, statements and model-check findings of a booted chapter.
      # @api private
      def read(chapter, hecksagon)
        { diagrams:   Projections::Diagrams.call(bluebook: chapter, options: { hecksagon: hecksagon }),
          statements: Projections::Statements.call(bluebook: chapter),
          findings:   Bluebook::ModelCheck.call(chapter, hecksagon: hecksagon).map(&:to_h) }
      end

      # What the chapter is wired to: the binds its hecksagon declares, the chapters it attaches,
      # the driving adapters it admits, the world's default adapter, and each declared port with
      # the adapters bound to it.
      #
      # @param registry [Runtime::Registry] a booted registry
      # @param name [String] the chapter's name
      # @return [Hash] `binds`, `attaches`, `driving`, `default_adapter` and `ports`
      def wiring(registry, name)
        hecksagon = registry.hecksagon(name)
        {
          binds:           (hecksagon&.binds || []).map { |bind| bind.to_h.slice(:aggregate, :verb, :adapter, :role) },
          attaches:        hecksagon&.member_chapters || [],
          driving:         hecksagon&.driving || [],
          default_adapter: registry.world(name)&.default_adapter,
          ports:           Runtime::CapabilityGraph.new(registry).fulfillments
        }
      end

      # @api private
      def empty(files, outline)
        { diagnostic: nil, files: files, outline: outline, chapter: nil, diagrams: {}, statements: [],
          findings: [], wiring: nil, board: nil }
      end
    end
  end
end
