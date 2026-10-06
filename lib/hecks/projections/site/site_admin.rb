# frozen_string_literal: true

require "json"
require_relative "../../projector"
require_relative "admin"
require_relative "routes_ts"
require_relative "site_admin/session"
require_relative "site_admin/access"

module Hecks
  module Projections
    module Site
      # A site's admin sign-in as one dependency-free TypeScript module, `admin.ts`.
      #
      # The module is what a site's middleware and pages need to ask the domain host who is signed
      # in and whether that person may use the admin pages: the session cookie's settings, a check
      # that the host's membership list holds the person as an admin, a gate that decides a path
      # from the route table's `auth` column, and the hand-off to the content system. It imports the
      # route table module beside it and nothing else, so it loads under Node and any bundler.
      #
      # The text is a pure function of the `Admin` row and the extension: nothing in it names a
      # time or a machine, so regenerating from the same row changes nothing.
      module SiteAdmin
        extend Projector::Target

        projects_as :site_admin, emits: :files

        module_function

        # Renders `admin.ts` for a project that declares an admin row.
        #
        # @param bluebook [Bluebook::Chapter] the chapter that declares the route table
        # @param options [Hash{Symbol => Object}] `:admin` (Admin) the checked admin row, or nil;
        #   `:extension` (String) the extension the routes module is written with, `ts` by default
        # @return [Hash{String => String}] `"admin.ts"` to its text; empty with no admin row
        def call(bluebook:, options: {})
          admin = options[:admin]
          return {} if admin.nil?

          { "admin.ts" => render(admin, options.fetch(:extension, "ts")) }
        end

        # @param admin [Admin] a checked admin row
        # @param extension [String] the extension of the route table module
        # @return [String] the module's text, ending in a newline
        def render(admin, extension)
          [RoutesTs::BANNER, header, imports(extension), settings(admin), Session::MEMO, helpers].join("\n\n") << "\n"
        end

        def header
          <<~TS.chomp
            // The admin sign-in of this site, projected from its bluebook's Admin row and Route rows. Change the
            // rows and run `hecks site site_projection.project_site`; with `--check` it fails when this file is out of date.
          TS
        end

        def imports(extension)
          %(import { MIDDLEWARE, ROUTES, matchesPath } from "./routes.#{extension}";)
        end

        def settings(admin)
          body = setting_fields(admin).map { |key, value| "  #{key}: #{RoutesTs.literal(value)}," }
          "/** What the sign-in is built from: the project's Admin row, defaults filled. */\n" \
            "export const ADMIN = {\n#{body.join("\n")}\n} as const;"
        end

        def setting_fields(admin)
          setting = admin.setting
          {
            sessionCookie: setting.session_cookie, sessionMaxAge: setting.session_max_age,
            hostEnv: setting.host_env, hostDefault: setting.host_default, roles: admin.roles,
            accountPath: setting.account_path, membersPath: setting.members_path,
            ssoTokenPath: setting.sso_token_path, ssoTarget: setting.sso_target, login: setting.login,
            sso: setting.sso, verdictTtlMs: setting.verdict_ttl_ms, timeoutMs: setting.timeout_ms
          }
        end

        def helpers
          [Session::CONFIGURATION, Session::MEMBERSHIP, Session::SESSIONS, Access::VERDICTS, Access::HANDOFF,
           Access::ROUTING, Access::GATE].join("\n\n")
        end
      end
    end
  end
end
