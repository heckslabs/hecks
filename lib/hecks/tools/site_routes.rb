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
require_relative "../projections/site/cms_editor"
require_relative "site_routes/cli"
require_relative "site_routes/templates"
require_relative "site_routes/root_files"
require_relative "site_routes/editor_files"

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
              "[--template=<file>] [--cms=<dir>] [--root=<dir>] [--editor=<dir>] " \
              "[--extension=#{EXTENSIONS.join("|")}] [--check]".freeze

      # The directory `ports/` and `adapters/` live under, loaded into every project's registry.
      LIB_HECKS = File.expand_path("..", __dir__)

      # The keywords `projection` takes, each nil until given.
      Settings = Struct.new(:out, :template, :extension, :cms, :root_dir, :editor, keyword_init: true)

      # A project's route-table chapter with its checked table and the registry it booted into.
      Site = Struct.new(:chapter, :table, :registry)

      extend Cli
      extend Templates
      extend RootFiles
      extend EditorFiles

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
        options, check = parse_flags(argv)
        project = argv.empty? ? root : File.expand_path(argv.shift)
        abort USAGE unless argv.empty?

        files = projection(project, **options)
        stale = stale_paths(files)
        return report(stale, project, check) if check

        write_stale(files, stale, project)
        0
      end

      # @param root [String] the project directory
      # @param options [Hash] the keywords, each optional:
      #   `out:` the directory to write to; `generated/` of the project when nil
      #   `template:` the template to rewrite in place, wherever it lies; the `Edge` row's
      #   template, relative to the project, when nil
      #   `extension:` `ts` (the default) or `mts`, the module's file extension
      #   `cms:` the directory for the content system's half of the admin sign-in
      #   `root_dir:` the directory for the project's root files
      #   `editor:` the directory for the content editor
      # @return [Hash{String => String}] each file's absolute path to the text it should hold
      # @raise [SystemExit] when the project declares no route table, the table is refused, or a
      #   path or the extension is refused
      def projection(root, **)
        settings = Settings.new(**)
        settings.extension ||= EXTENSIONS.first
        refuse_extension(settings.extension)
        dir = output_dir(root, settings)
        registry = registry_for(root)
        chapter = Projections::Site::Table.chapter(registry)
        site = Site.new(chapter, Projections::Site::Table.read(chapter, registry: registry), registry)
        assemble(root, dir, site, settings)
      rescue Projections::Site::Table::Invalid => e
        abort "project_site: #{e.message}"
      end

      # @return [Hash{String => String}] every file the project's rows write, by absolute path
      def assemble(root, dir, site, settings)
        written = route_files(dir, site, settings.extension)
        admin = Projections::Site::Admin.read(site.chapter, table: site.table)
        written.merge!(admin_files(dir, site.chapter, admin, settings.extension))
        written.merge!(optional_files(settings, site, admin, root))
        written.merge(template_files(root, settings.out, site, template: settings.template))
      end

      # @return [Hash{String => String}] the route table module, by absolute path
      def route_files(dir, site, extension)
        files = Projector.call(:site_routes_ts, bluebook: site.chapter, options: { table: site.table })
        renamed(dir, files, extension)
      end

      # The content system's files, the project's root files and the editor, each when its flag was
      # given.
      def optional_files(settings, site, admin, project)
        files = {}
        files.merge!(cms_files(settings.cms, site.chapter, admin)) if settings.cms
        files.merge!(root_files(settings.root_dir, site.chapter)) if settings.root_dir
        files.merge!(editor_files(settings.editor, project, site)) if settings.editor
        files
      end

      # @return [Hash{String => String}] `files` placed under `dir`, with the module extension
      #   applied
      def renamed(dir, files, extension)
        files.to_h { |name, text| [File.join(dir, name.sub(/\.ts\z/, ".#{extension}")), text] }
      end

      # @raise [SystemExit] when `extension` is not one the module may take
      def refuse_extension(extension)
        return if EXTENSIONS.include?(extension)

        abort "project_site: --extension is one of #{EXTENSIONS.join(", ")}, not #{extension.inspect}"
      end

      # @return [String] the directory the route table module is written to
      # @raise [SystemExit] when that path is a file
      def output_dir(root, settings)
        dir = settings.out ? File.expand_path(settings.out) : File.join(root, DEFAULT_OUT)
        return dir unless File.file?(dir)

        abort "project_site: --out #{dir} is a file; it names the directory routes.#{settings.extension} goes in"
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
        renamed(dir, files, extension)
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
        Hecks.with_registry(registry) { load_project(dir) }
        registry
      end

      # Loads the attached ports and adapters, then the project's bluebooks and hecksagons.
      def load_project(dir)
        %w[ports/persistence.port ports/extraction.port adapters/driven/memory.adapter
           adapters/driven/prism.adapter].each { |file| Kernel.load(File.join(LIB_HECKS, file)) }
        Dir.glob(File.join(dir, "*.bluebook")).each { |file| Kernel.load(file) }
        Dir.glob(File.join(dir, "*.hecksagon")).each { |file| Kernel.load(file) }
      end
    end
  end
end
