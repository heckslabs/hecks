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
                        title: String, skip: String, media: String, media_dir: String, media_max_bytes: String },
            required: %i[domain chapter host_env login],
            defaults: { base_path: "/editor", session_cookie: "hecks_editor", host_cookie: "hecks_session",
                        host_default: "http://127.0.0.1:4322", roles: "Admin,Owner", title: "Editor", skip: "",
                        media: "", media_dir: "media", media_max_bytes: "5242880" }
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
            @row = { sso_path: "#{row[:base_path]}/api/sso" }.merge(row)
            problems = Checks.problems(@row, roles, table)
            return if problems.empty?

            raise Table::Invalid, "the Editor row is refused:\n#{problems.map { |line| "  - #{line}" }.join("\n")}"
          end

          # @return [String] the domain's directory, relative to the project
          def domain = row.fetch(:domain)

          # @return [String] the chapter the editor edits
          def chapter = row.fetch(:chapter)

          # @return [String, nil] the other chapter whose picture aggregate the editor's pictures
          #   use, or nil when the pictures (if any) are in the editor's own chapter
          def media_chapter = row.fetch(:media).strip.then { |name| name.empty? ? nil : name }

          # @return [Array<String>] the aggregates left out
          def skip = row.fetch(:skip).split(",").map(&:strip).reject(&:empty?)

          # @return [Array<String>] the roles that count as an editor
          def roles = row.fetch(:roles).split(",").map(&:strip).reject(&:empty?)

          # @return [String] the generated package's name
          def package = "#{chapter.gsub(/([a-z])([A-Z])/, '\1-\2').tr("_", "-").downcase}-editor"

          # @return [Hash{String => String}] each placeholder to the text that replaces it
          def tokens
            { "__BANNER__" => RoutesTs::BANNER, "__PACKAGE__" => package, "__ROLES__" => RoutesTs.literal(roles),
              "__MEDIA_MAX_BYTES__" => row.fetch(:media_max_bytes),
              "__CLIENT_VERSION__" => Hecks::VERSION, **quoted }
          end

          # @return [Hash{String => String}] each text field's placeholder to the field as JSON
          def quoted
            { "TITLE" => :title, "BASE_PATH" => :base_path, "SSO_PATH" => :sso_path, "LOGIN" => :login,
              "SESSION_COOKIE" => :session_cookie, "HOST_COOKIE" => :host_cookie, "HOST_ENV" => :host_env,
              "HOST_DEFAULT" => :host_default, "MEDIA_DIR" => :media_dir }
              .to_h { |token, field| ["__#{token}__", JSON.generate(row.fetch(field))] }
          end
        end
      end
    end
  end
end
