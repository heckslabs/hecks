# frozen_string_literal: true

require "fileutils"

module Hecks
  module Adapters
    # The imperative half of tenant provisioning, behind `Deploy::Tenant.port
    # "TenantProvisioning"`; booting the domain and its capability gate stay in bin/project_tenant.
    class TenantProvisioner
      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Writes the tenant's environment overlay file under its domain directory.
      #
      # `directory:` must be passed explicitly — a domain's declared name is not a
      # filesystem path. Each argument arrives either bare or wrapped as `{ value: }`.
      #
      # @param slug [String, Hash] names the overlay file
      # @param directory [String, Hash] the domain's own directory on disk
      # @return [Hash{Symbol => Object}] `:slug`, `:domain`, `:realm` and `:schema`, as given
      def provision(slug:, domain:, realm:, schema:, database:, adapter:, directory:)
        domain_directory = File.expand_path(directory[:value] || directory)

        overlay_path = File.join(domain_directory, "environments", "#{slug[:value] || slug}.world")
        FileUtils.mkdir_p(File.dirname(overlay_path))
        File.write(overlay_path, <<~WORLD)
          Hecks.world "#{domain[:value] || domain}" do
            realm "#{realm[:value] || realm}"
            persisted_by("#{adapter[:value] || adapter}") do
              database "#{database[:value] || database}"
              schema   "#{schema[:value] || schema}"
            end
          end
        WORLD

        { slug: slug, domain: domain, realm: realm, schema: schema }
      end
    end
  end
end
