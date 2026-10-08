# frozen_string_literal: true

require_relative "preview"
require_relative "scale_checks"
require_relative "theme_checks"

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

          # The largest upload size cap a row may name: 100 MiB.
          MAX_UPLOAD = 104_857_600

          module_function

          # @param row [Hash{Symbol => String}] the row, defaults filled
          # @param roles [Array<String>] the roles the row names
          # @param table [Table, nil] the checked route table, to check the login page against
          # @return [Array<String>] every problem, in the order the fields are declared
          def problems(row, roles, table)
            base = row[:base_path]
            [*path_problems(row, base), *("Editor roles name no role" if roles.empty?), *login_problems(row[:login], table),
             *media_problems(row), *media_chapter_problems(row), *ThemeChecks.problems(row), *ScaleChecks.problems(row),
             *Preview.problems(row[:preview].strip)]
          end

          # @return [Array<String>] the problems with the base path and the sign-in path
          def path_problems(row, base)
            found = []
            found << "base_path #{base.inspect} must start with a slash and not end with one" unless BASE_PATH.match?(base)
            found << "sso_path #{row[:sso_path]} must be under #{base}/" unless row[:sso_path].start_with?("#{base}/")
            found
          end

          # @return [Array<String>] the problems with the picture directory and the upload size cap
          def media_problems(row)
            found = []
            found << "media_dir must not be empty" if row[:media_dir].strip.empty?
            cap = row[:media_max_bytes]
            unless cap.match?(/\A[1-9]\d{0,9}\z/) && cap.to_i <= MAX_UPLOAD
              found << "media_max_bytes #{cap.inspect} must be a whole number of bytes from 1 to #{MAX_UPLOAD}"
            end
            found
          end

          # @return [Array<String>] the problem with a `media` chapter that is one the editor edits
          def media_chapter_problems(row)
            named = row[:media].strip
            return [] unless row[:chapter].split(",").map(&:strip).include?(named)

            ["media #{named.inspect} is this editor's own chapter; name another chapter"]
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
