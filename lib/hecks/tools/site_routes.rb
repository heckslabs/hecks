# frozen_string_literal: true

require "hecks"
require "fileutils"
require "optparse"
require_relative "../tools"
require_relative "../projections/site/routes_ts"
require_relative "../projections/site/site_cdn"
require_relative "../projections/site/regions"
require_relative "../projections/site/admin"
require_relative "../projections/site/site_admin"
require_relative "../projections/site/admin_cms"
require_relative "../projections/site/site_root"
require_relative "../projections/site/site_host"
require_relative "../projections/site/payload_driver"

module Hecks
  module Tools
    # Projects a project's route table into `routes.ts` (`Projections::Site::RoutesTs`), its edge
    # into the behaviours and listener rules of its template (`Projections::Site::SiteCdn`) and its
    # `Admin` row into `admin.ts` (`Projections::Site::SiteAdmin`), each when it declares one.
    #
    #   hecks site site_projection.project_site [<project>] [--out=<dir>] [--template=<file>]
    #       [--cms=<dir>] [--root=<dir>] [--extension=ts|mts] [--check]
    #
    # `<project>` (default: the working directory) holds `bluebook/` and the `vendor/` it attaches
    # from. `routes.ts` goes to `<project>/generated` or to `--out`, anywhere. The template is the
    # `Edge` row's, relative to the project, or `--template`, anywhere; it is rewritten in place
    # between its `BEGIN`/`END GENERATED site_cdn` markers. With `--out` alone, `--out` receives a
    # copy of it instead. `--extension=mts` names the module `routes.mts`; `--check` writes nothing.
    module SiteRoutes
      # Where the files go, relative to the project, when `--out` names no directory.
      DEFAULT_OUT = "generated"

      # The extensions the module may take; the first is the default.
      EXTENSIONS = %w[ts mts].freeze

      USAGE = "usage: hecks site site_projection.project_site [<project>] [--out=<dir>] " \
              "[--template=<file>] [--cms=<dir>] [--root=<dir>] [--extension=#{EXTENSIONS.join("|")}] [--check]".freeze

      module_function

      # Projects the route table, writes what differs and prints a line for each file written.
      #
      # @param argv [Array<String>] the project directory, then the flags
      # @param root [String] the project used when `argv` names none; the working directory
      # @return [Integer] 0, or 1 when `--check` finds a file out of date
      # @raise [SystemExit] with the reason on stderr when the project declares no route table, the
      #   table is refused, or a flag is refused
      def main(argv, root: Dir.pwd)
        argv = argv.dup
        out = template = extension = cms = root_dir = nil
        check = false
        OptionParser.new do |parser|
          parser.on("--out=DIR") { |value| out = value }
          parser.on("--template=FILE") { |value| template = value }
          parser.on("--cms=DIR") { |value| cms = value }
          parser.on("--root=DIR") { |value| root_dir = value }
          parser.on("--extension=EXT") { |value| extension = value }
          parser.on("--check") { check = true }
        end.parse!(argv)
        project = argv.empty? ? root : File.expand_path(argv.shift)
        abort USAGE unless argv.empty?

        files = projection(project, out: out, template: template, extension: extension, cms: cms, root_dir: root_dir)
        stale = files.reject { |path, text| File.file?(path) && File.read(path) == text }.keys
        return report(stale, project, check) if check

        stale.each do |path|
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, files.fetch(path))
          puts "wrote #{display(path, project)}"
        end
        puts "project_site: #{files.size} #{files.size == 1 ? "file" : "files"}, current" if stale.empty?
        0
      end

      # @param root [String] the project directory
      # @param out [String, nil] the directory to write to; `generated/` of the project when nil
      # @param template [String, nil] the template to rewrite in place, wherever it lies; the
      #   `Edge` row's template, relative to the project, when nil
      # @param extension [String, nil] `ts` (the default) or `mts`, the module's file extension
      # @return [Hash{String => String}] each file's absolute path to the text it should hold
      # @raise [SystemExit] when the project declares no route table, the table is refused, or a
      #   path or the extension is refused
      def projection(root, out: nil, template: nil, extension: nil, cms: nil, root_dir: nil)
        extension ||= EXTENSIONS.first
        unless EXTENSIONS.include?(extension)
          abort "project_site: --extension is one of #{EXTENSIONS.join(", ")}, not #{extension.inspect}"
        end
        dir = out ? File.expand_path(out) : File.join(root, DEFAULT_OUT)
        abort "project_site: --out #{dir} is a file; it names the directory routes.#{extension} goes in" if File.file?(dir)

        registry = registry_for(root)
        chapter = Projections::Site::Table.chapter(registry)
        table = Projections::Site::Table.read(chapter, registry: registry)
        files = Projector.call(:site_routes_ts, bluebook: chapter, options: { table: table })
        written = files.to_h { |name, text| [File.join(dir, name.sub(/\.ts\z/, ".#{extension}")), text] }
        admin = Projections::Site::Admin.read(chapter, table: table)
        written.merge!(admin_files(dir, chapter, admin, extension))
        written.merge!(cms_files(cms, chapter, admin)) if cms
        written.merge!(root_files(root_dir, chapter)) if root_dir
        written.merge(template_files(root, out, chapter, table, registry, template: template))
      rescue Projections::Site::Table::Invalid => e
        abort "project_site: #{e.message}"
      end

      # The admin sign-in module, when the project declares an `Admin` row.
      #
      # @param dir [String] the directory the route table module is written to
      # @param chapter [Bluebook::Chapter] the chapter that declares the route table
      # @param admin [Projections::Site::Admin, nil] the checked admin row
      # @param extension [String] the extension the modules are written with
      # @return [Hash{String => String}] the module's path to its text; empty with no admin row
      def admin_files(dir, chapter, admin, extension)
        files = Projector.call(:site_admin, bluebook: chapter, options: { admin: admin, extension: extension })
        files.to_h { |name, text| [File.join(dir, name.sub(/\.ts\z/, ".#{extension}")), text] }
      end

      # The files at the project's root that its rows write: the settings template, the workflow,
      # the
      # content system's image and start-up script, and the files that drive the domain.
      #
      # @param dir [String] the directory they are written under, relative to the working directory
      # @param chapter [Bluebook::Chapter] the chapter that declares the route table
      # @return [Hash{String => String}] each file's absolute path to its text; empty with no rows
      def root_files(dir, chapter)
        base = File.expand_path(dir)
        files = Projector.call(:site_root, bluebook: chapter).merge(Projector.call(:site_host, bluebook: chapter))
        files = files.merge(payload_files(base, chapter))
        files.to_h { |name, text| [File.join(base, name), text] }
      end

      # The files that drive the project's domain from the content system, when it declares a
      # `Payload` row.
      #
      # @param base [String] the directory the project's root files are written under
      # @param chapter [Bluebook::Chapter] the chapter that declares the route table and the rows
      # @return [Hash{String => String}] each file's path relative to `base` to its text
      def payload_files(base, chapter)
        row = Projections::Site::PayloadDriver::PAYLOAD.read(chapter).first
        return {} unless row

        domain_root = File.join(base, row[:domain])
        domain = registry_for(domain_root).bluebooks.values.find { |candidate| candidate.name == row[:chapter] }
        abort "project_site: #{domain_root} declares no chapter #{row[:chapter]}" unless domain
        Projector.call(:payload_driver, bluebook: chapter, options: { domain_chapter: domain })
      rescue ArgumentError => e
        abort "project_site: #{e.message}"
      end

      # The content system's half of the admin sign-in: four files under the `--cms` directory.
      #
      # @param cms [String] the directory the files are written under
      # @param chapter [Bluebook::Chapter] the chapter that declares the route table
      # @param admin [Projections::Site::Admin, nil] the checked admin row
      # @return [Hash{String => String}] each file's absolute path to its text
      # @raise [SystemExit] when `--cms` is named and the project declares no `Admin` row
      def cms_files(cms, chapter, admin)
        abort "project_site: --cms names #{cms}, but the project declares no Admin row" if admin.nil?

        files = Projector.call(:site_admin_cms, bluebook: chapter, options: { admin: admin })
        files.to_h { |name, text| [File.join(File.expand_path(cms), name), text] }
      end

      # The template with the edge's regions rewritten, when the project declares an edge.
      #
      # @param root [String] the project directory
      # @param out [String, nil] the directory to write to, or nil to rewrite the template in place
      # @param chapter [Bluebook::Chapter] the chapter that declares the route table
      # @param table [Projections::Site::Table] the checked table
      # @param registry [Hecks::Runtime::Registry] the registry the project booted into
      # @param template [String, nil] a template named on the command line, rewritten in place
      # @return [Hash{String => String}] the template's path to its text; empty with no edge
      # @raise [SystemExit] when a template is named and the project declares no edge, the
      #   template is missing or lacks a region it needs, or holds a region an edge without a load
      #   balancer does not use
      def template_files(root, out, chapter, table, registry, template: nil)
        edge = Projections::Site::Edge.read(chapter, table: table, template: template,
                                                     vocabulary: Projections::Site::Table.vocabulary(registry))
        unless edge
          abort "project_site: --template names #{template}, but the project declares no Edge rows" if template
          return {}
        end

        regions = Projector.call(:site_cdn, bluebook: chapter, options: { table: table, edge: edge })
        relative = template || edge.setting.template
        source = template ? File.expand_path(template) : File.join(root, relative)
        unless File.file?(source)
          abort "project_site: the template #{relative} does not exist#{" in #{root}" unless template}"
        end

        text = rewritten(File.read(source), regions, relative, edge)
        in_place = template || out.nil?
        { (in_place ? source : File.join(File.expand_path(out), relative)) => text }
      end

      # @param text [String] the template
      # @param regions [Hash{String => String}] each region's name to the block that goes in it
      # @param relative [String] the template's name, for a message
      # @param edge [Projections::Site::Edge] the checked edge
      # @return [String] the template with each region rewritten
      # @raise [SystemExit] when a region is missing, or a listener_rules region is left behind
      #   by an edge with no load balancer
      def rewritten(text, regions, relative, edge)
        if !edge.alb? && Projections::Site::Regions.region?(text, "listener_rules")
          abort "project_site: #{relative} has a BEGIN/END GENERATED site_cdn listener_rules region, " \
                "and the Edge row says alb: false; remove the region"
        end
        regions.reduce(text) do |current, (name, block)|
          unless Projections::Site::Regions.region?(current, name)
            abort "project_site: #{relative} has no BEGIN/END GENERATED site_cdn #{name} region"
          end

          Projections::Site::Regions.replace(current, name, block)
        end
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

        warn "project_site: out of date: #{stale.map { |path| display(path, project) }.join(", ")} " \
             "(run hecks site site_projection.project_site)"
        1
      end

      # @param path [String] an absolute path
      # @param project [String] the project directory
      # @return [String] the path relative to the project when it lies beneath it
      def display(path, project) = path.delete_prefix("#{project}/")
    end
  end
end
