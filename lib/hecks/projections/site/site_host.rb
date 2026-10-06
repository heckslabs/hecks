# frozen_string_literal: true

require "json"
require_relative "../../projector"
require_relative "root_rows"
require_relative "site_host/templates"

module Hecks
  module Projections
    module Site
      # The content system's container image and its start-up script, from rows beside the route
      # table: `cms/Dockerfile` and `cms/deploy-aws/boot.mjs`.
      #
      # The script resolves the content system's secrets before it starts the server: the database
      # password and the signing secret always, and any further secret a `BootSecret` row names.
      # Each is
      # fetched from Secrets Manager in the process, so none is ever a plaintext environment
      # variable of
      # the task. The image is a plain two-stage build of a Next standalone server that runs the
      # script.
      module SiteHost
        extend Projector::Target

        projects_as :site_host, emits: :files

        # The `Cms` row: where the content system lives and how its image is built.
        CMS = RootRows.new("Cms", fields:   { dir: String, node: String, port: Integer, heap_mb: Integer },
                                  defaults: { dir: "cms", node: "22", port: 8080, heap_mb: 1024 })

        # A `BootSecret` row: an environment variable filled from a secret whose id the variable
        # `from`
        # holds. With `field` the secret is JSON and that field is the value, required once the
        # secret
        # is named; without it the whole secret is the value and failing to read it only warns.
        BOOT_SECRETS = RootRows.new("BootSecret", fields: { env: String, from: String, field: String },
                                                  required: %i[env from], many: true)

        module_function

        # @param bluebook [Bluebook::Chapter] the chapter that declares the route table
        # @param options [Hash{Symbol => Object}] unused
        # @return [Hash{String => String}] each file's path relative to the project root to its
        #   text;
        #   empty when the project declares no `Cms` row
        # @raise [Table::Invalid] when a row is refused
        def call(bluebook:, options: {})
          cms = CMS.read(bluebook).first
          return {} unless cms

          secrets = BOOT_SECRETS.read(bluebook)
          { "#{cms[:dir]}/Dockerfile"          => Templates.dockerfile(cms),
            "#{cms[:dir]}/deploy-aws/boot.mjs" => Templates.boot(secrets) }
        end
      end
    end
  end
end
