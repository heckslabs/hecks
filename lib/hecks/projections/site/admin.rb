# frozen_string_literal: true

require_relative "table"

module Hecks
  module Projections
    module Site
      # What a site's route table cannot say about who may use its admin pages: the session cookie,
      # the host that vouches for it, the roles that count as an admin, and the two routes the
      # sign-in is built from.
      #
      # A project declares one `member` row of a `value_object "Admin"` in the chapter that holds
      # its route table. `docs/site-routes.md` lists the fields. A project that declares none has
      # no admin sign-in to project.
      class Admin
        Setting = Struct.new(:session_cookie, :session_max_age, :host_env, :host_default, :roles,
                             :account_path, :members_path, :sso_token_path, :sso_target, :login,
                             :sso, :verdict_ttl_ms, :timeout_ms, :cms_base, keyword_init: true)

        # The value object a project declares its admin row in.
        OBJECT = "Admin"

        # The fields the row may carry, with the Ruby class each takes.
        FIELDS = {
          session_cookie: String, session_max_age: Integer, host_env: String, host_default: String,
          roles: String, account_path: String, members_path: String, sso_token_path: String,
          sso_target: String, login: String, sso: String, verdict_ttl_ms: Integer, timeout_ms: Integer,
          cms_base: String
        }.freeze

        # The fields the row must carry.
        REQUIRED = %i[session_cookie host_env login sso].freeze

        # What a field takes when the row does not carry it.
        DEFAULTS = {
          session_max_age: 14 * 24 * 60 * 60, host_default: "http://127.0.0.1:4322",
          roles: "Admin,Owner", account_path: "/accounts/me", members_path: "/members",
          sso_token_path: "/accounts/sso-token", sso_target: "/cms/api/sso",
          verdict_ttl_ms: 10_000, timeout_ms: 5_000, cms_base: "/cms"
        }.freeze

        # The fields that name a path on the host or the content system, which start with a slash.
        PATH_FIELDS = %i[account_path members_path sso_token_path sso_target cms_base].freeze

        # @return [Setting] the checked row, defaults filled
        attr_reader :setting

        # Reads and checks the admin row a chapter declares.
        #
        # @param chapter [Bluebook::Chapter] the chapter that declares the route table
        # @param table [Table] the checked route table
        # @return [Admin, nil] the checked setting, or nil when the chapter declares none
        # @raise [Table::Invalid] when the row is refused or contradicts the routes
        def self.read(chapter, table:)
          members = Table.rows_of(chapter, OBJECT)
          return nil if members.empty?

          new(members, table: table)
        end

        # @param members [Array<Hash{Symbol => Object}>] the declared rows
        # @param table [Table] the checked route table
        # @raise [Table::Invalid] naming every problem when there is one
        def initialize(members, table:)
          problems = []
          problems << "a project declares one Admin row, not #{members.size}" if members.size > 1
          row = members.first
          typed = typed_fields(row, problems)
          @setting = Setting.new(**DEFAULTS, **typed)
          check(table.rows, problems) if problems.empty?
          return if problems.empty?

          raise Table::Invalid, "the admin sign-in is refused:\n#{problems.map { |line| "  - #{line}" }.join("\n")}"
        end

        # @return [Array<String>] the roles that count as an admin
        def roles = setting.roles.split(",").map(&:strip).reject(&:empty?)

        # @return [String] the path of the content system's sign-in endpoint inside its own API, the
        #   part of `sso_target` after `<cms_base>/api`
        def cms_endpoint = setting.sso_target.delete_prefix("#{setting.cms_base}/api")

        private

        def typed_fields(row, problems)
          unknown = row.keys - FIELDS.keys
          problems << "Admin row has no field #{unknown.join(', ')}; fields are #{FIELDS.keys.join(', ')}" if unknown.any?
          (REQUIRED - row.keys).each { |field| problems << "Admin row needs #{field}" }
          row.slice(*FIELDS.keys).select do |field, value|
            value.is_a?(FIELDS.fetch(field)) ||
              (problems << "Admin row has #{field} #{value.inspect}; #{field} is a #{FIELDS.fetch(field)}")
          end
        end

        def check(rows, problems)
          check_paths(problems)
          check_cms_base(problems)
          problems << "Admin roles name no role" if roles.empty?
          check_login(rows, problems)
          check_sso(rows, problems)
        end

        def check_paths(problems)
          (PATH_FIELDS + %i[login sso]).each do |field|
            value = setting[field]
            problems << "Admin #{field} #{value.inspect} must start with a slash" unless value.start_with?("/")
          end
        end

        # The sign-in endpoint is the content system's own API route, under its base path.
        def check_cms_base(problems)
          return if setting.sso_target.start_with?("#{setting.cms_base}/api/")

          problems << "Admin sso_target #{setting.sso_target} must be under #{setting.cms_base}/api/"
        end

        # The login page is a public row: a visitor with no session must reach it.
        def check_login(rows, problems)
          row = rows.find { |candidate| candidate.path == setting.login }
          if row.nil?
            problems << "Admin login #{setting.login} is not a route of the table"
          elsif row.auth != "public"
            problems << "Admin login #{setting.login} is #{row.auth}; the login page must be public"
          end
        end

        # The hand-off to the content system is an admin endpoint: it answers only an admin.
        def check_sso(rows, problems)
          row = rows.find { |candidate| candidate.path == setting.sso }
          if row.nil?
            problems << "Admin sso #{setting.sso} is not a route of the table"
          else
            problems << "Admin sso #{setting.sso} is #{row.auth}; it must be admin" unless row.auth == "admin"
            problems << "Admin sso #{setting.sso} is a #{row.kind}; it must be an endpoint" unless row.kind == "endpoint"
          end
        end
      end
    end
  end
end
