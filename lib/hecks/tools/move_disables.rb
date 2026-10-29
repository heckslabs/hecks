# frozen_string_literal: true

require "hecks"
require_relative "../tools"
require_relative "move_disables/reasons"

module Hecks
  module Tools
    # Moves justified inline RuboCop disables into `.rubocop.yml`, one entry per cop, each carrying
    # its reason once. A file in `SKIP` keeps its inline disables until someone decides or refactors
    # it; the move does not touch them.
    #
    #   hecks ScriptRun.plan_script! script=move_disables      # what would move, writing nothing
    #   hecks ScriptRun.apply_script! script=move_disables confirm=true
    module MoveDisables
      CONFIG = ".rubocop.yml"

      CONFIG_HEADING = "# Overrides moved from inline `rubocop:disable` comments; each cop states its reason once."

      # Files whose disables need a decision or a refactor first.
      SKIP = %w[
        lib/hecks/runtime/registry.rb
        lib/hecks/runtime/registry/context_maps.rb
        lib/hecks/adapters/driving/ruby/aggregate_module.rb
        lib/hecks/bluebook/dsl/generic_dispatch.rb
        lib/hecks/query_ir/touchpoints.rb
        spec/adapters/driven/postgres_era/era_resolver_role_spec.rb
      ].freeze

      DIRECTIVE = /^\s*#\s*rubocop:(disable-next|disable)\s+(.+)$/
      TRAILING = /\s+#\s*rubocop:disable(?:-next)?\s+(.+)$/
      TRAILING_COMMENT = /\s+#\s*rubocop:disable.*$/
      ENABLE = /^\s*#\s*rubocop:enable\s+(.+)$/

      # A cop that would move has no reason written in `REASONS`.
      class MissingReason < StandardError; end

      module_function

      # Runs from a checkout's root, as a script: `hecks ... move_disables [--apply]`.
      #
      # @param argv [Array<String>] `--apply` writes the files; without it, the plan only
      # @param root [String] the checkout to work on
      # @return [Integer] 0
      def main(argv, root: ROOT)
        puts transform(root: root, apply: argv.include?("--apply"))
        0
      end

      # Plans the move, and writes it when `apply` is true.
      #
      # @param root [String] the checkout to work on
      # @param apply [Boolean] whether to write the files and the config
      # @return [String] the plan: each cop with the files it moves from, and what was written
      # @raise [MissingReason] when a cop that would move has no reason in `REASONS`
      def transform(root:, apply:)
        edits, moves = scan(root)
        refuse_missing_reasons(moves)

        config, merged, blocks = config_with(root, moves)
        report = plan_report(edits, moves, merged)
        return "#{report}\ndry run; apply with confirm=true" unless apply

        write(root, edits, written_config(config, blocks))
        "#{report}\napplied"
      end

      # @param moves [Hash{String => Array<String>}] the files each cop moves from
      # @raise [MissingReason] when a cop that would move has no reason in `REASONS`
      def refuse_missing_reasons(moves)
        missing = moves.keys - REASONS.keys
        raise MissingReason, "no reason written for: #{missing.join(", ")}" unless missing.empty?
      end

      # @param root [String] the checkout
      # @param edits [Hash{String => String}] the new text of each file that changes
      # @param config [String] the config's new text
      # @return [void]
      def write(root, edits, config)
        edits.each { |path, text| File.write(File.join(root, path), text) }
        File.write(File.join(root, CONFIG), config)
      end

      # @param edits [Hash{String => String}] the new text of each file that changes
      # @param moves [Hash{String => Array<String>}] the files each cop moves from
      # @param merged [Array<String>] the cops merged into blocks already in the config
      # @return [String] one line per cop, with its file count
      def plan_report(edits, moves, merged)
        lines = ["files to edit: #{edits.size}"]
        moves.keys.sort.each do |cop|
          lines << format("  %<cop>-32s %<count>2d file(s)", cop: cop, count: moves[cop].uniq.size)
        end
        lines << "merged into existing blocks: #{merged.join(", ")}" unless merged.empty?
        lines.join("\n")
      end

      # Each Ruby file under lib and spec with a directive to move, with the text it becomes.
      #
      # @param root [String] the checkout
      # @return [Array(Hash{String => String}, Hash{String => Array<String>})] the new text of each
      #   file, and the files each cop moves from
      def scan(root)
        moves = Hash.new { |hash, cop| hash[cop] = [] }
        edits = {}
        scanned_paths(root).each do |path|
          touched, text = strip(File.readlines(File.join(root, path), chomp: true))
          next if touched.empty?

          touched.uniq.each { |cop| moves[cop] << path }
          edits[path] = text
        end
        [edits, moves]
      end

      # @param root [String] the checkout
      # @return [Array<String>] the Ruby files under lib and spec, in order, outside `SKIP`
      def scanned_paths(root)
        Dir.glob(%w[lib/**/*.rb spec/**/*.rb], base: root).sort.reject { |path| SKIP.include?(path) }
      end

      # Removes the directives from one file's lines.
      #
      # @param lines [Array<String>] the file's lines, without their newlines
      # @return [Array(Array<String>, String)] the cops the directives named, and the file's new text
      def strip(lines)
        touched = []
        out = lines.filter_map { |line| keep_line(line, touched) }
        out = out.reject { |line| closes_removed?(line, touched) }
        [touched, "#{out.join("\n")}\n"]
      end

      # @param line [String] one line of the file
      # @param touched [Array<String>] the cops removed so far; this line's cops are added to it
      # @return [String, nil] the line without its directive, or nil when the line is a directive
      def keep_line(line, touched)
        if (match = DIRECTIVE.match(line))
          touched.concat(cops_from(match[2]))
          return nil
        end
        return line unless (match = TRAILING.match(line))

        touched.concat(cops_from(match[1]))
        line.sub(TRAILING_COMMENT, "")
      end

      # A block-form enable is closed by a disable that was removed; it goes once its cops are gone.
      #
      # @param line [String] one line of the file
      # @param touched [Array<String>] the cops the file's removed directives named
      # @return [Boolean] whether the line is an enable whose cops were all removed
      def closes_removed?(line, touched)
        match = ENABLE.match(line)
        match && (cops_from(match[1]) - touched).empty?
      end

      # @param text [String] the cops of one directive, possibly followed by a ` -- reason`
      # @return [Array<String>] the cop names
      def cops_from(text)
        reason_free = text.split(" -- ").first
        reason_free.split(",").map(&:strip).reject(&:empty?)
      end

      # Adds each moved cop to the config: a new block, or an `Exclude` under an existing one.
      #
      # @param root [String] the checkout
      # @param moves [Hash{String => Array<String>}] the files each cop moves from
      # @return [Array(String, Array<String>, Array<String>)] the config text with the existing
      #   blocks filled, the cops merged into existing blocks, and the new blocks to append
      def config_with(root, moves)
        config = File.read(File.join(root, CONFIG))
        merged, added = moves.keys.sort.partition { |cop| config.match?(header_line(cop)) }
        [fill_blocks(config, merged, moves), merged, added.map { |cop| new_block(cop, excluded_paths(moves[cop])) }]
      end

      # @param config [String] the config's text
      # @param merged [Array<String>] the cops whose blocks already exist in the config
      # @param moves [Hash{String => Array<String>}] the files each cop moves from
      # @return [String] the config with each existing block given its `Exclude`
      def fill_blocks(config, merged, moves)
        merged.inject(config) { |text, cop| text.sub(header_line(cop)) { merged_block(cop, excluded_paths(moves[cop])) } }
      end

      # @param cop [String] a cop name
      # @return [Regexp] the config line that opens the cop's block
      def header_line(cop) = /^#{Regexp.escape("#{cop}:")}$/

      # @param files [Array<String>] the files a cop moves from
      # @return [Array<String>] the `Exclude` entries, sorted and unique
      def excluded_paths(files) = files.uniq.sort.map { |path| %(    - "#{path}") }

      # @param cop [String] a cop name
      # @param paths [Array<String>] the `Exclude` entries
      # @return [String] the cop's header, its reason, and its `Exclude`, to replace an existing header
      def merged_block(cop, paths) = ["#{cop}:", "  # #{REASONS.fetch(cop)}", "  Exclude:", *paths].join("\n")

      # @param cop [String] a cop name
      # @param paths [Array<String>] the `Exclude` entries
      # @return [String] a new block for the cop, with its reason above it
      def new_block(cop, paths) = ["# #{REASONS.fetch(cop)}", "#{cop}:", "  Exclude:", *paths].join("\n")

      # @param config [String] the config as it stands, with existing blocks filled
      # @param blocks [Array<String>] the new blocks to append
      # @return [String] the config with the new blocks appended under a heading
      def written_config(config, blocks)
        return config if blocks.empty?

        "#{config.rstrip}\n\n#{CONFIG_HEADING}\n#{blocks.join("\n\n")}\n"
      end
    end
  end
end
