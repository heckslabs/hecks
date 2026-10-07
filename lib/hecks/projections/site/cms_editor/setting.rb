# frozen_string_literal: true

require "json"
require_relative "../root_rows"
require_relative "../routes_ts"
require_relative "checks"
require_relative "../../../version"

module Hecks
  module Projections
    module Site
      module CmsEditor
        # The project's `Editor` row, checked: which domain chapter the editor edits, where the
        # editor is served, the session cookie it keeps, and the host and sign-in it reads.
        #
        # `docs/site-routes.md` lists the fields. A project that declares no row has no editor to
        # project.
        class Setting
          # The `Editor` row: its fields, which are required and what the others default to.
          ROW = RootRows.new(
            "Editor",
            fields:   { domain: String, chapter: String, base_path: String, sso_path: String, session_cookie: String,
                        host_cookie: String, host_env: String, host_default: String, roles: String, login: String,
                        title: String, brand: String, accent: String, logo: String, skip: String, media: String,
                        media_dir: String, media_max_bytes: String, chapter_roles: String, page_size: [String, Integer] },
            required: %i[domain chapter host_env login],
            defaults: { base_path: "/editor", session_cookie: "hecks_editor", host_cookie: "hecks_session",
                        host_default: "http://127.0.0.1:4322", roles: "Admin,Owner", title: "Editor", brand: "",
                        accent: "", logo: "", skip: "", media: "", media_dir: "media", media_max_bytes: "5242880",
                        chapter_roles: "", page_size: "25" }
          )

          # @return [Hash{Symbol => String}] the checked row, defaults filled
          attr_reader :row

          # Reads and checks the row a chapter declares.
          #
          # @param chapter [Bluebook::Chapter] the chapter that declares the route table
          # @param table [Table, nil] the checked route table, to check the login page against
          # @return [Setting, nil] the checked setting, or nil when the chapter declares no row
          # @raise [Table::Invalid] when the row is refused
          def self.read(chapter, table: nil)
            row = ROW.read(chapter).first
            row && new(row, table: table)
          end

          # @param row [Hash{Symbol => String}] the row, defaults filled
          # @param table [Table, nil] the checked route table
          # @raise [Table::Invalid] naming every problem when there is one
          def initialize(row, table: nil)
            @row = { sso_path: "#{row[:base_path]}/api/sso" }.merge(row, page_size: row[:page_size].to_s)
            problems = Checks.problems(@row, roles, table)
            return if problems.empty?

            raise Table::Invalid, "the Editor row is refused:\n#{problems.map { |line| "  - #{line}" }.join("\n")}"
          end

          # @return [String] the domain's directory, relative to the project
          def domain = row.fetch(:domain)

          # @return [String] the first chapter the editor edits, which names the generated package
          def chapter = chapters.first.to_s

          # @return [Array<String>] every chapter the editor edits, in the order the row names them:
          #   `chapter` is one name or several, comma separated
          def chapters = row.fetch(:chapter).split(",").map(&:strip).reject(&:empty?)

          # @return [Hash{String => Array<String>}] the roles a chapter's aggregates are limited to,
          #   from `Chapter=Role,Role;Chapter=Role`; a chapter not named is open to every role the
          #   editor admits
          def chapter_roles
            row.fetch(:chapter_roles).split(";").map(&:strip).reject(&:empty?).to_h do |entry|
              name, roles = entry.split("=", 2)
              [name.to_s.strip, roles.to_s.split(",").map(&:strip).reject(&:empty?)]
            end
          end

          # @return [Integer] how many instances a list shows to a page
          def page_size = row.fetch(:page_size).to_i

          # @return [String, nil] the other chapter whose picture aggregate the editor's pictures
          #   use, or nil when the pictures (if any) are in the editor's own chapter
          def media_chapter = row.fetch(:media).strip.then { |name| name.empty? ? nil : name }

          # @return [String, nil] the product name the header shows, or nil for the domain's name
          def brand = row.fetch(:brand).strip.then { |name| name.empty? ? nil : name }

          # @return [String, nil] the accent colour as hex, or nil for the default theme
          def accent = row.fetch(:accent).strip.then { |hex| hex.empty? ? nil : hex }

          # @return [Array<String>] the aggregates left out: `Name`, or `Chapter::Name`
          def skip = row.fetch(:skip).split(",").map(&:strip).reject(&:empty?)

          # @return [Array<String>] the roles that count as an editor
          def roles = row.fetch(:roles).split(",").map(&:strip).reject(&:empty?)

          # @return [String] the generated package's name
          def package = "#{chapter.gsub(/([a-z])([A-Z])/, '\1-\2').tr("_", "-").downcase}-editor"

          # @return [Hash{String => String}] each placeholder to the text that replaces it
          def tokens
            { "__BANNER__" => RoutesTs::BANNER, "__PACKAGE__" => package, "__ROLES__" => RoutesTs.literal(roles),
              "__MEDIA_MAX_BYTES__" => row.fetch(:media_max_bytes), "__PAGE_SIZE__" => page_size.to_s,
              "__CLIENT_VERSION__" => Hecks::VERSION, **quoted }
          end

          # @return [Hash{String => String}] each text field's placeholder to the field as JSON
          def quoted
            { "TITLE" => :title, "BASE_PATH" => :base_path, "SSO_PATH" => :sso_path, "LOGIN" => :login,
              "SESSION_COOKIE" => :session_cookie, "HOST_COOKIE" => :host_cookie, "HOST_ENV" => :host_env,
              "HOST_DEFAULT" => :host_default, "MEDIA_DIR" => :media_dir, "LOGO" => :logo }
              .to_h { |token, field| ["__#{token}__", JSON.generate(row.fetch(field))] }
          end
        end
      end
    end
  end
end
