# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module SiteRoutes
      # The editor's files, written under the `--editor` directory when the project declares an
      # `Editor` row.
      module EditorFiles
        # @param editor [String] the directory the files are written under
        # @param project [String] the project directory; the row's `domain` is relative to it
        # @param site [Site] the project's route-table chapter, checked table and registry
        # @return [Hash{String => String}] each file's absolute path to its text
        # @raise [SystemExit] when `--editor` is named and the project declares no `Editor` row, or
        #   the row names a domain or chapter that is not there
        def editor_files(editor, project, site)
          setting = Projections::Site::CmsEditor::Setting.read(site.chapter, table: site.table)
          abort "project_site: --editor names #{editor}, but the project declares no Editor row" if setting.nil?

          files = Projector.call(:site_cms_editor, bluebook: site.chapter, options: options(project, setting, site))
          files.to_h { |name, text| [File.join(File.expand_path(editor), name), text] }
        rescue ArgumentError, Projections::Site::Table::Invalid => e
          abort "project_site: #{e.message}"
        end

        # @return [Hash{Symbol => Object}] the chapters the editor reads, and the route table
        def options(project, setting, site)
          chosen = { domain_chapter: domain_chapter(project, setting), table: site.table }
          chosen[:media_chapter] = domain_chapter(project, setting, setting.media_chapter) if setting.media_chapter
          chosen
        end

        # @param name [String] the chapter to find; the row's `chapter` unless given
        # @return [Bluebook::Chapter] the chapter the `Editor` row names, from its domain directory
        def domain_chapter(project, setting, name = setting.chapter)
          domain_root = File.join(project, setting.domain)
          chapter = registry_for(domain_root).bluebooks.values.find { |candidate| candidate.name == name }
          abort "project_site: #{domain_root} declares no chapter #{name}" unless chapter
          chapter
        end
      end
    end
  end
end
