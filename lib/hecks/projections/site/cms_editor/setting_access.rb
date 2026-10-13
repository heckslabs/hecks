# frozen_string_literal: true

require "json"
require_relative "../routes_ts"

module Hecks
  module Projections
    module Site
      module CmsEditor
        # What the `Editor` row says about who signs in and who administers: the roles that manage
        # the people, the address that starts the host's sign-in, and the path the host sends a
        # person to once it has signed them in; and where the site itself is reached from the
        # editor's server. Read from the row a `Setting` holds.
        module SettingAccess
          # @return [Array<String>] the roles that manage who may edit (the People screen)
          def admin_roles = row.fetch(:admin_roles).split(",").map(&:strip).reject(&:empty?)

          # @return [String, nil] the path the host sends a person to once Google has signed them
          #   in (the host's own `/admin.html`), which the edge routes to the editor so that
          #   everyone the list admits arrives in it, not on the site's administrator-only page
          def landing = row.fetch(:landing).strip.then { |path| path.empty? ? nil : path }

          # @return [String, nil] the address that starts a sign-in on the site's own origin (the
          #   host's Google sign-in), which the editor's own sign-in page leads to; nil for none
          def sign_in = row.fetch(:sign_in).strip.then { |path| path.empty? ? nil : path }

          # @return [Hash{String => String}, nil] where the site is reached from the editor's server
          #   (the environment variable that names its address, and a default), which the editor
          #   reads the site's own sitemap from to leave hidden pages out; nil when the row names none
          def site
            env = row.fetch(:site_env).strip
            env.empty? ? nil : { "env" => env, "default" => row.fetch(:site_default).strip }
          end

          # @return [Hash{String => String}] the placeholders of `config.ts` these four fill
          def access_tokens
            { "__ADMIN_ROLES__" => RoutesTs.literal(admin_roles), "__SIGN_IN__" => JSON.generate(sign_in),
              "__LANDING__" => JSON.generate(landing), "__SITE__" => JSON.generate(site) }
          end
        end
      end
    end
  end
end
