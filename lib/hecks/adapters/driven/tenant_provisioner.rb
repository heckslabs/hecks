# frozen_string_literal: true

require "fileutils"

module Hecks
  module Adapters
    # The imperative half of tenant provisioning, behind `Deploy::Tenant.port
    # "TenantProvisioning"`, for `Tenant.Provision` and for bin/project_tenant; booting the domain
    # and its capability gate stay in bin/project_tenant.
    class TenantProvisioner
      # Raised when a value is outside its allow-list or the overlay path leaves `environments/`.
      class Refused < ArgumentError; end

      # Each argument's allow-list. `\A...\z` anchors: `$` would let a newline end the value early.
      IDENTIFIER = /\A[a-z][a-z0-9_]*\z/
      LABEL      = /\A[A-Za-z0-9][A-Za-z0-9_ .:-]*\z/
      CONSTANT   = /\A[A-Z][A-Za-z0-9]*\z/
      CONNECTION = /\A[^\x00-\x20\x7f]+\z/

      RULES = { slug: IDENTIFIER, schema: IDENTIFIER, domain: LABEL, realm: LABEL,
                database: CONNECTION, adapter: CONSTANT }.freeze

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Writes the tenant's environment overlay under `<directory>/environments/`.
      #
      # Each argument arrives bare or wrapped as `{ value: }`; the record's other fields are
      # ignored. Values are allow-listed and written as Ruby string literals.
      #
      # @param slug [String, Hash] names the overlay file
      # @param directory [String, Hash] the domain's own directory on disk (not its declared name)
      # @param adapter [String, Hash, nil] the adapter the overlay binds; PostgresEra when none
      # @return [Hash{Symbol => Object}] `:slug`, `:domain`, `:realm`, `:schema` and `:output`
      # @raise [Refused] when a value is outside its allow-list or the path leaves `environments/`
      def write_overlay(slug:, domain:, realm:, schema:, database:, directory:, adapter: nil, **)
        values = { slug: unwrap(slug), domain: unwrap(domain), realm: unwrap(realm),
                   schema: unwrap(schema), database: unwrap(database),
                   adapter: adapter_name(adapter) }
        values.each { |name, value| check(name, value) }

        overlay_path = overlay_path_for(unwrap(directory), values[:slug])
        FileUtils.mkdir_p(File.dirname(overlay_path))
        File.write(overlay_path, render(values))

        { slug: slug, domain: domain, realm: realm, schema: schema,
          output: { value: "wrote #{overlay_path}\n" } }
      end

      private

      def render(values)
        <<~WORLD
          Hecks.world #{values[:domain].inspect} do
            realm #{values[:realm].inspect}
            persisted_by(#{values[:adapter].inspect}) do
              database #{values[:database].inspect}
              schema   #{values[:schema].inspect}
            end
          end
        WORLD
      end

      def unwrap(argument) = argument.is_a?(Hash) ? argument[:value] : argument

      def check(name, value)
        return if value.is_a?(String) && RULES.fetch(name).match?(value)

        raise Refused, "#{name} #{value.inspect} is not an accepted #{name}"
      end

      def overlay_path_for(directory, slug)
        raise Refused, "directory is required" unless directory.is_a?(String) && !directory.empty?

        environments = File.join(File.expand_path(directory), "environments")
        path = File.expand_path("#{slug}.world", environments)
        return path if path.start_with?("#{environments}#{File::SEPARATOR}")

        raise Refused, "overlay path #{path} is outside #{environments}"
      end

      def adapter_name(adapter)
        name = unwrap(adapter)
        name.nil? || name.to_s.empty? ? "PostgresEra" : name
      end
    end
  end
end
