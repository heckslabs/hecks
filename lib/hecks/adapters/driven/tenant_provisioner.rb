# frozen_string_literal: true

require "fileutils"

module Hecks
  module Adapters
    # The imperative half of tenant provisioning, behind `Deploy::Tenant.port
    # "TenantProvisioning"`: it writes the tenant's overlay world, then boots the domain under it
    # (which provisions the schema) and checks every chapter is tenant_capable.
    class TenantProvisioner
      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Writes the tenant's overlay world under its domain directory, then boots the domain under
      # it and checks it is tenant_capable.
      #
      # `directory:` must be passed explicitly: a domain's declared name is not a path. Each
      # argument arrives bare or wrapped as `{ value: }`; other keys of the record are ignored.
      #
      # @param slug [String, Hash] names the overlay file
      # @param directory [String, Hash] the domain's own directory on disk
      # @param adapter [String, Hash, nil] the persistence adapter; PostgresEra when absent
      # @return [Hash{Symbol => Object}] `:slug`, `:domain`, `:realm` and `:schema`, as given
      # @raise [ArgumentError] if the directory does not exist
      # @raise [Runtime::WiringError] if the domain is not tenant_capable under the overlay
      def establish(slug:, domain:, realm:, schema:, database:, directory:, adapter: nil, **)
        domain_directory = File.expand_path(plain(directory))
        raise ArgumentError, "no such domain directory: #{domain_directory}" unless File.directory?(domain_directory)

        write_overlay(domain_directory, slug: plain(slug), domain: plain(domain), realm: plain(realm),
                                        schema: plain(schema), database: plain(database),
                                        adapter: plain(adapter) || "PostgresEra")
        verify_tenant_capable(domain_directory, plain(slug))

        { slug: slug, domain: domain, realm: realm, schema: schema }
      end

      private

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument

      def write_overlay(directory, slug:, domain:, realm:, schema:, database:, adapter:)
        overlay_path = File.join(directory, "environments", "#{slug}.world")
        FileUtils.mkdir_p(File.dirname(overlay_path))
        File.write(overlay_path, <<~WORLD)
          Hecks.world "#{domain}" do
            realm "#{realm}"
            persisted_by("#{adapter}") do
              database "#{database}"
              schema   "#{schema}"
            end
          end
        WORLD
      end

      # The boot also provisions the schema: PostgresEra#connect_for runs an idempotent create
      # schema. Every chapter is checked, not just the one named, after a real boot.
      def verify_tenant_capable(directory, slug)
        require_relative "../../../hecks"
        require_relative "../../ports/persistence/plugins/era"
        booted = Hecks.boot(directory, environment: slug, install_facade: false)
        booted.registry.bluebooks.each_key do |name|
          Runtime::TenantCheck.refuse_unless_tenant_capable!(booted.registry, name)
        end
      end
    end
  end
end
