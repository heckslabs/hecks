# frozen_string_literal: true

require "json"
require_relative "../../projector"
require_relative "cms_editor/setting"
require_relative "cms_editor/schema"

module Hecks
  module Projections
    module Site
      # A small Node/TypeScript editor for a domain's content, as the files of a package: a server
      # that signs editors in through the site's own hand-off and shows a page per aggregate, a list
      # from its queries, a detail page per instance and a form per command.
      #
      # It is generic by aggregate. The pages and forms are not written per aggregate; they read
      # `src/schema.ts`, which is the domain chapter's aggregates, attributes, value objects,
      # lifecycles, commands and queries as one typed constant. The domain holds no editor data: the
      # editor reads and dispatches through the host like any other client, and the output is a pure
      # function of the chapter and the `Editor` row, so `--check` can hold it current.
      module CmsEditor
        extend Projector::Target

        projects_as :site_cms_editor, emits: :files

        # Where the template files are.
        TEMPLATES = File.join(__dir__, "cms_editor", "templates")

        # The files, by path relative to the directory they are written to.
        FILES = %w[
          package.json tsconfig.json src/config.ts src/schema.ts src/host.ts src/commands.ts src/app.ts src/server.ts
          src/auth/membership.ts src/auth/session.ts src/auth/sso.ts
          src/ui/html.ts src/ui/outline.ts src/ui/fields.ts src/ui/input.ts src/ui/pages.ts
        ].freeze

        module_function

        # Renders the editor's files for a project that declares an `Editor` row.
        #
        # @param bluebook [Bluebook::Chapter] the chapter that declares the route table and the row
        # @param options [Hash{Symbol => Object}] `:domain_chapter` the chapter to edit; `:table`
        #   the checked route table, when the login page is to be checked against it
        # @return [Hash{String => String}] each file's path relative to the editor's directory to
        #   its text; empty when the project declares no `Editor` row
        # @raise [Table::Invalid] when the row is refused
        # @raise [ArgumentError] when the chapter has no aggregate to edit
        def call(bluebook:, options: {})
          setting = Setting.read(bluebook, table: options[:table])
          return {} unless setting

          schema = Schema.read(options.fetch(:domain_chapter), skip: setting.skip)
          tokens = setting.tokens.merge("__SCHEMA__" => JSON.pretty_generate(schema))
          FILES.to_h { |path| [path, fill(File.read(File.join(TEMPLATES, "#{path}.tmpl")), tokens)] }
        end

        # @param text [String] a template with `__NAME__` placeholders
        # @param tokens [Hash{String => String}] each placeholder to its text
        # @return [String] `text` with each placeholder replaced in one pass, so a value that looks
        #   like a placeholder is left as it is
        def fill(text, tokens) = text.gsub(/__[A-Z_]+__/) { |token| tokens.fetch(token, token) }
      end
    end
  end
end
