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

          # A wall-clock zone: `Z` or a fixed offset.
          ZONE = /\A(?:Z|[+-]\d\d:\d\d)\z/

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
             *Preview.problems(row[:preview].strip), *preview_in_problems(row), *zone_problems(row), *wiring_problems(row)]
          end

          # @return [Array<String>] the problems with where files go, who may edit and the
          #   Markdown modules
          def wiring_problems(row)
            [*upload_problems(row), *members_problems(row), *markdown_problems(row), *sign_in_problems(row)]
          end

          # @return [Array<String>] the problem with a sign-in address that is not a path on the
          #   site's own origin
          def sign_in_problems(row)
            %i[sign_in landing].flat_map do |field|
              path = row[field].strip
              next [] if path.empty? || (path.start_with?("/") && !path.start_with?("//"))

              ["#{field} #{path.inspect} must be a path on the site's own origin, starting with one slash"]
            end
          end

          # A module the editor imports at build time: a relative path to a TypeScript or
          # JavaScript file, `#`, and the name it exports.
          MODULE = %r{\A\.\.?/[\w./-]+\.(?:ts|mts|js|mjs)#[A-Za-z_$][\w$]*\z}

          # @return [Array<String>] the problems with where uploads are sent: an API root that
          #   starts with a slash, and a default address or environment variable that is given
          def upload_problems(row)
            api = row[:upload_api].strip
            return [] if api.empty? && row[:upload_env].strip.empty? && row[:upload_default].strip.empty?

            [*("upload_api #{api.inspect} must start with a slash and not end with one" unless BASE_PATH.match?(api)),
             *("upload_env must name the environment variable the content system is read from" if row[:upload_env].strip.empty?)]
          end

          # @return [Array<String>] the problem with the aggregate that holds the people, when it is
          #   not `Domain::Aggregate`
          def members_problems(row)
            named = row[:members_aggregate].strip
            return [] if named.empty? || named.match?(/\A\w+::\w+\z/)

            ["members_aggregate #{named.inspect} must be Domain::Aggregate, such as Membership::Person"]
          end

          # @return [Array<String>] the problems with the two modules the Markdown preview imports
          def markdown_problems(row)
            named = %i[markdown_parse markdown_render].to_h { |field| [field, row[field].strip] }
            return [] if named.values.all?(&:empty?)

            [*named.reject { |_, path| path.match?(MODULE) }.map { |field, path| module_problem(field, path) },
             *("markdown_parse and markdown_render are named together" if named.value?(""))]
          end

          # @return [String] what is wrong with a module a row names
          def module_problem(field, path)
            "#{field} #{path.inspect} must be a relative path to a .ts or .js module and the name it exports, " \
              "such as ../src/read.ts#read"
          end

          # @return [Array<String>] the problem with `zone`, when it is not `Z` or an offset
          def zone_problems(row)
            ZONE.match?(row[:zone]) ? [] : ["zone #{row[:zone].inspect} must be Z or an offset such as -07:00"]
          end

          # @return [Array<String>] the problem with `preview_in`, when it is neither word
          def preview_in_problems(row)
            %w[drawer tab].include?(row[:preview_in]) ? [] : ["preview_in #{row[:preview_in].inspect} must be drawer or tab"]
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
