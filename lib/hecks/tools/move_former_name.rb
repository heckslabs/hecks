# frozen_string_literal: true

require_relative "../tools"
require_relative "../naming"

module Hecks
  module Tools
    # Moves an aggregate's `formerly_known_as "Old"` out of the bluebook and into the world that
    # names the domain, as `stored_as Name: "old"`: the physical name an aggregate's rows are
    # stored under is a storage fact, so the world says it. The bluebook line is removed, the world
    # line is added (the world file is created beside the bluebook when the domain has none), and
    # nothing else changes: a translation edge already carries the rename for the data.
    #
    #   hecks move_former_name [--dry-run]
    module MoveFormerName
      # One aggregate-level `formerly_known_as` found in a bluebook.
      Candidate = Struct.new(:file, :domain, :aggregate, :former, keyword_init: true)

      SKIPPED          = %r{(^|/)(\.claude|\.git|node_modules|rust|spec|tmp|vendor)/}
      DOMAIN_LINE      = /^\s*Hecks\.bluebook\s+"([^"]+)"/
      AGGREGATE_LINE   = /^\s*aggregate\s+"([^"]+)"/
      FORMERLY_LINE    = /^\s*formerly_known_as\s+"([^"]+)"\s*$/
      WORLD_LINE_START = /^(\s*Hecks\.world\s+"%<domain>s"\s+do\n)/
      BLUEBOOK_EXT     = /\.bluebook\z/

      module_function

      # @param argv [Array<String>] `--dry-run` to print what would change and write nothing
      # @param root [String] the checkout whose bluebooks are read
      # @return [Integer] 0
      def main(argv, root: Tools::ROOT)
        dry_run = argv.include?("--dry-run")
        found = candidates(root)
        puts "no aggregate-level formerly_known_as found" if found.empty?
        found.group_by(&:file).each { |file, group| move(file, group, root, dry_run) }
        0
      end

      # @param root [String] the checkout
      # @return [Array<Candidate>] every aggregate-level `formerly_known_as` under the root
      def candidates(root) = files_under(root, "bluebook").flat_map { |file| in_file(file) }

      # @param root [String] the checkout
      # @param extension [String] `bluebook` or `world`
      # @return [Array<String>] the files with that extension, outside the folders left alone
      def files_under(root, extension)
        Dir.glob(File.join(root, "**/*.#{extension}")).reject { |file| file.delete_prefix("#{root}/").match?(SKIPPED) }
      end

      # @param file [String] a bluebook
      # @return [Array<Candidate>] its aggregates that carry the word
      def in_file(file)
        text = File.read(file)
        domain = text[DOMAIN_LINE, 1]
        return [] unless domain

        owner = nil
        text.each_line.filter_map do |line|
          owner = Regexp.last_match(1) if line =~ AGGREGATE_LINE
          next unless owner && line =~ FORMERLY_LINE

          Candidate.new(file: file, domain: domain, aggregate: owner, former: Regexp.last_match(1))
        end
      end

      # Rewrites one bluebook and writes or prints the world lines that replace its words.
      def move(file, group, root, dry_run)
        world = world_file_for(file, group.first.domain, root)
        lines = group.map { |c| "#{c.aggregate}: #{Naming.snake(c.former).inspect}" }
        puts "#{rel(file, root)}: remove #{group.size} formerly_known_as line(s)"
        puts "#{rel(world, root)}: add `stored_as #{lines.join(", ")}`"
        write(file, world, group, lines) unless dry_run
      end

      def write(file, world, group, lines)
        File.write(file, strip(File.read(file), group))
        File.write(world, with_stored_as(world, group.first.domain, lines))
      end

      def strip(text, group)
        group.reduce(text) { |t, c| t.sub(/^[ \t]*formerly_known_as\s+"#{Regexp.escape(c.former)}"[ \t]*\n/, "") }
      end

      # The world file that already names the domain, else `<bluebook>.world` beside the bluebook.
      def world_file_for(file, domain, root)
        named = files_under(root, "world").sort.find { |world| names_domain?(world, domain) }
        named || file.sub(BLUEBOOK_EXT, ".world")
      end

      def names_domain?(world, domain)
        !world.include?(".local.") && File.read(world).match?(/^\s*Hecks\.world\s+"#{Regexp.escape(domain)}"/)
      end

      def with_stored_as(world, domain, lines)
        statement = "  stored_as #{lines.join(", ")}\n"
        return "Hecks.world #{domain.inspect} do\n#{statement}end\n" unless File.exist?(world)

        start = Regexp.new(format(WORLD_LINE_START.source, domain: Regexp.escape(domain)))
        File.read(world).sub(start) { "#{Regexp.last_match(1)}#{statement}" }
      end

      def rel(path, root) = path.delete_prefix("#{root}/")
    end
  end
end
