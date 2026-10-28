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
        # @param site [Site] the project's route-table bluebook, checked table and registry
        # @return [Hash{String => String}] each file's absolute path to its text
        # @raise [SystemExit] when `--editor` is named and the project declares no `Editor` row, or
        #   the row names a domain or bluebook that is not there
        def editor_files(editor, project, site)
          setting = Projections::Site::CmsEditor::Setting.read(site.declaration, table: site.table)
          abort "project_site: --editor names #{editor}, but the project declares no Editor row" if setting.nil?

          files = Projector.call(:site_cms_editor, bluebook: site.declaration, options: options(project, setting, site))
          files.to_h { |name, text| [File.join(File.expand_path(editor), name), text] }
        rescue ArgumentError, Projections::Site::Table::Invalid => e
          abort "project_site: #{e.message}"
        end

        # @return [Hash{Symbol => Object}] the bluebooks the editor reads, and the route table
        def options(project, setting, site)
          chosen = { domain_bluebooks: setting.bluebooks.map do |name|
            domain_bluebook(project, setting, name)
          end, table: site.table }
          chosen[:media_bluebook] = domain_bluebook(project, setting, setting.media_bluebook) if setting.media_bluebook
          chosen
        end

        # @param name [String] the bluebook to find; the row's first `bluebook` unless given
        # @return [Bluebook::Declaration] the bluebook the `Editor` row names, from its domain
        #   directory
        def domain_bluebook(project, setting, name = setting.bluebook)
          domain_root = File.join(project, setting.domain)
          declaration = registry_for(domain_root).bluebooks.values.find { |candidate| candidate.name == name }
          abort "project_site: #{domain_root} declares no bluebook #{name}" unless declaration
          declaration
        end
      end
    end
  end
end
