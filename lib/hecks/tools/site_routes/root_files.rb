# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module SiteRoutes
      # The files outside `generated/`: the project's root files and the content system's half of
      # the admin sign-in.
      module RootFiles
        # The files at the project's root that its rows write: the settings template, the workflow,
        # the content system's image and start-up script, and the files that drive the domain.
        #
        # @param dir [String] the directory they are written under, relative to the working
        #   directory
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
      end
    end
  end
end
