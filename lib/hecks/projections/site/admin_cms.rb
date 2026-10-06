# frozen_string_literal: true

require "json"
require_relative "../../projector"
require_relative "admin"
require_relative "routes_ts"
require_relative "admin_cms/templates"

module Hecks
  module Projections
    module Site
      # The content system's half of a site's admin sign-in, as four TypeScript files for a Payload
      # project: the membership check, the session strategy, the sign-in endpoint and the users
      # collection.
      #
      # The site half (`SiteAdmin`) sends a signed-in admin to the content system with a short-lived
      # token. These files accept it: the endpoint verifies the token, asks the domain host whether
      # the person is still admitted and mints an ordinary session; the strategy asks the host again
      # on every later request; the users collection has no passwords and cannot be created over its
      # API. They read the same `Admin` row as the site half, so the two cannot disagree.
      module AdminCms
        extend Projector::Target

        projects_as :site_admin_cms, emits: :files

        # The files, by path relative to the directory they are written to.
        FILES = %w[auth/membership.ts auth/sessionStrategy.ts endpoints/sso.ts collections/Users.ts].freeze

        module_function

        # Renders the four files for a project that declares an admin row.
        #
        # @param bluebook [Bluebook::Chapter] the chapter that declares the route table
        # @param options [Hash{Symbol => Object}] `:admin` (Admin) the checked admin row, or nil
        # @return [Hash{String => String}] each file's relative path to its text; empty with no row
        def call(bluebook:, options: {})
          admin = options[:admin]
          return {} if admin.nil?

          tokens = tokens(admin)
          FILES.to_h { |path| [path, fill(templates.fetch(path), tokens)] }
        end

        # @param admin [Admin] a checked admin row
        # @return [Hash{String => String}] each placeholder to the TypeScript text that replaces it
        def tokens(admin)
          setting = admin.setting
          {
            "__BANNER__"       => RoutesTs::BANNER,
            "__COOKIE__"       => JSON.generate(setting.session_cookie),
            "__HOST_ENV__"     => JSON.generate(setting.host_env),
            "__HOST_DEFAULT__" => JSON.generate(setting.host_default),
            "__ROLES__"        => RoutesTs.literal(admin.roles),
            "__ACCOUNT_PATH__" => JSON.generate(setting.account_path),
            "__MEMBERS_PATH__" => JSON.generate(setting.members_path),
            "__ENDPOINT__"     => JSON.generate(admin.cms_endpoint),
            "__CMS_PREFIX__"   => JSON.generate("#{setting.cms_base}/"),
            "__CMS_ADMIN__"    => JSON.generate("#{setting.cms_base}/admin"),
            "__SSO_TARGET__"   => setting.sso_target
          }
        end

        def fill(text, tokens) = tokens.reduce(text) { |filled, (token, value)| filled.gsub(token, value) }

        def templates
          { "auth/membership.ts" => Templates.membership, "auth/sessionStrategy.ts" => Templates.session_strategy,
            "endpoints/sso.ts" => Templates.sso, "collections/Users.ts" => Templates.users }
        end
      end
    end
  end
end
