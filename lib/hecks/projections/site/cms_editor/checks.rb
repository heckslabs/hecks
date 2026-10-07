# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        # What the `Editor` row must satisfy beyond the class of each field: paths that start with
        # a slash, a sign-in path the editor serves itself, a role to admit, and a login page a
        # visitor with no session can reach.
        module Checks
          # A base path: one or more segments, starting with a slash and not ending with one.
          BASE_PATH = %r{\A(/[^/\s]+)+\z}

          module_function

          # @param row [Hash{Symbol => String}] the row, defaults filled
          # @param roles [Array<String>] the roles the row names
          # @param table [Table, nil] the checked route table, to check the login page against
          # @return [Array<String>] every problem, in the order the fields are declared
          def problems(row, roles, table)
            base = row[:base_path]
            [*path_problems(row, base), *("Editor roles name no role" if roles.empty?), *login_problems(row[:login], table)]
          end

          # @return [Array<String>] the problems with the base path and the sign-in path
          def path_problems(row, base)
            found = []
            found << "base_path #{base.inspect} must start with a slash and not end with one" unless BASE_PATH.match?(base)
            found << "sso_path #{row[:sso_path]} must be under #{base}/" unless row[:sso_path].start_with?("#{base}/")
            found
          end

          # The login page is a public row: a visitor with no session must reach it.
          #
          # @return [Array<String>] the problems with the login page
          def login_problems(login, table)
            return ["login #{login} must start with a slash"] unless login.start_with?("/")
            return [] if table.nil?

            found = table.rows.find { |candidate| candidate.path == login }
            return ["login #{login} is not a route of the table"] if found.nil?

            found.auth == "public" ? [] : ["login #{login} is #{found.auth}; the login page must be public"]
          end
        end
      end
    end
  end
end
