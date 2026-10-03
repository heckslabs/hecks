# frozen_string_literal: true

require "hecks"
require "fileutils"
require "optparse"
require_relative "../tools"
require_relative "../projections/site/routes_ts"
require_relative "../projections/site/site_cdn"
require_relative "../projections/site/regions"

module Hecks
  module Tools
    # Projects a project's route table into `routes.ts` (`Projections::Site::RoutesTs`) and, when
    # it declares an edge, into the behaviours and listener rules of its template
    # (`Projections::Site::SiteCdn`).
    #
    #   hecks project_site [<project>] [--out=<dir>] [--check]
    #
    # `<project>` is the directory whose `bluebook/` holds the chapter that declares the rows and a
    # hecksagon that attaches Site; it defaults to the checkout. `routes.ts` is written to
    # `<project>/generated` unless `--out` names another directory. The template is rewritten in
    # place between its `BEGIN`/`END GENERATED site_cdn` markers, or under `--out` a copy of it is
    # written at the same relative path. With `--check` nothing is written: the tool answers 1 and
    # names each file that differs from the table.
    module SiteRoutes
      # Where the files go, relative to the project, when `--out` names no directory.
      DEFAULT_OUT = "generated"

      USAGE = "usage: hecks project_site [<project>] [--out=<dir>] [--check]"

      module_function

      # Projects the route table, writes what differs and prints a line for each file written.
      #
      # @param argv [Array<String>] the project directory, then the flags
      # @param root [String] the checkout, used as the project when `argv` names none
      # @return [Integer] 0, or 1 when `--check` finds a file out of date
      # @raise [SystemExit] with the reason on stderr when the project declares no route table or
      #   the table is refused
      def main(argv, root: Tools::ROOT)
        argv = argv.dup
        out = nil
        check = false
        OptionParser.new do |parser|
          parser.on("--out=DIR") { |value| out = value }
          parser.on("--check") { check = true }
        end.parse!(argv)
        project = argv.empty? ? root : File.expand_path(argv.shift)
        abort USAGE unless argv.empty?

        files = projection(project, out: out)
        stale = files.reject { |path, text| File.file?(path) && File.read(path) == text }.keys
        return report(stale, project, check) if check

        stale.each do |path|
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, files.fetch(path))
          puts "wrote #{display(path, project)}"
        end
        puts "project_site: #{files.size} #{files.size == 1 ? 'file' : 'files'}, current" if stale.empty?
        0
      end

      # @param root [String] the project directory
      # @param out [String, nil] the directory to write to; `generated/` of the project when nil
      # @return [Hash{String => String}] each file's absolute path to the text it should hold
      # @raise [SystemExit] when the project declares no route table or the table is refused
      def projection(root, out: nil)
        registry = registry_for(root)
        chapter = Projections::Site::Table.chapter(registry)
        table = Projections::Site::Table.read(chapter, registry: registry)
        files = Projector.call(:site_routes_ts, bluebook: chapter, options: { table: table })
        dir = out ? File.expand_path(out) : File.join(root, DEFAULT_OUT)
        written = files.to_h { |name, text| [File.join(dir, name), text] }
        written.merge(template_files(root, out, chapter, table, registry))
      rescue Projections::Site::Table::Invalid => e
        abort "project_site: #{e.message}"
      end

      # The template with the edge's regions rewritten, when the project declares an edge.
      #
      # @param root [String] the project directory
      # @param out [String, nil] the directory to write to, or nil to rewrite the template in place
      # @param chapter [Bluebook::Chapter] the chapter that declares the route table
      # @param table [Projections::Site::Table] the checked table
      # @param registry [Hecks::Runtime::Registry] the registry the project booted into
      # @return [Hash{String => String}] the template's path to its text; empty with no edge
      # @raise [SystemExit] when the template is missing or lacks a region
      def template_files(root, out, chapter, table, registry)
        edge = Projections::Site::Edge.read(chapter, table: table, vocabulary: Projections::Site::Table.vocabulary(registry))
        return {} unless edge

        regions = Projector.call(:site_cdn, bluebook: chapter, options: { table: table, edge: edge })
        relative = edge.setting.template
        source = File.join(root, relative)
        abort "project_site: the template #{relative} does not exist in #{root}" unless File.file?(source)

        text = regions.reduce(File.read(source)) do |current, (name, block)|
          unless Projections::Site::Regions.region?(current, name)
            abort "project_site: #{relative} has no BEGIN/END GENERATED site_cdn #{name} region"
          end

          Projections::Site::Regions.replace(current, name, block)
        end
        { (out ? File.join(File.expand_path(out), relative) : source) => text }
      end

      # Loads the project's chapters the way a deploy does: the bluebooks, then the hecksagons that
      # attach the chapters they need.
      #
      # @param root [String] the project directory
      # @return [Hecks::Runtime::Registry] the registry
      # @raise [SystemExit] when the project has no `bluebook/` directory
      def registry_for(root)
        dir = File.join(root, "bluebook")
        unless Dir.exist?(dir)
          abort "project_site: #{dir} does not exist; a project declares its route table in a bluebook/ directory"
        end

        registry = Hecks::Runtime::Registry.new(root: root)
        lib_hecks = File.expand_path("..", __dir__)
        Hecks.with_registry(registry) do
          %w[ports/persistence.port ports/extraction.port adapters/driven/memory.adapter
             adapters/driven/prism.adapter].each { |file| Kernel.load(File.join(lib_hecks, file)) }
          Dir.glob(File.join(dir, "*.bluebook")).each { |file| Kernel.load(file) }
          Dir.glob(File.join(dir, "*.hecksagon")).each { |file| Kernel.load(file) }
        end
        registry
      end

      # @param stale [Array<String>] absolute paths whose text differs from the table
      # @param project [String] the project directory
      # @param check [Boolean] whether this is a `--check` run
      # @return [Integer] 0 when current, else 1 with the stale files on stderr
      def report(stale, project, _check)
        if stale.empty?
          puts "project_site: every file current"
          return 0
        end

        warn "project_site: out of date: #{stale.map { |path| display(path, project) }.join(', ')} " \
             "(run hecks project_site)"
        1
      end

      # @param path [String] an absolute path
      # @param project [String] the project directory
      # @return [String] the path relative to the project when it lies beneath it
      def display(path, project) = path.delete_prefix("#{project}/")
    end
  end
end
