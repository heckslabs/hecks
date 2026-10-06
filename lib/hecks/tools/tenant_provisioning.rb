# frozen_string_literal: true

require "hecks"
# --adapter=PostgresEra needs the era persistence plugin (ADR 0033).
require "hecks/ports/persistence/plugins/era"
require "optparse"
require_relative "../tools"

module Hecks
  module Tools
    # Provisions a tenant: validates the declared shape, writes the `.world` overlay through the
    # `TenantProvisioning` port, boots once, and checks `tenant_capable?` and the Tenancy record.
    #
    # Deploy and Tenancy boot into one shared registry so the `translates` reaction in
    # tenancy.hecksagon can see Deploy's `TenantProvisioned` event. The overlay replaces (shallow
    # merge) the base `persisted_by` settings, so `--database` is required. A policy's refusal is
    # swallowed by `PolicyInterpreter#deliver`, so success is confirmed by query.
    #
    #   hecks deploy tenant.provision <domain-directory> <slug> --domain=name --realm=name \
    #     --schema=name --database=name [--adapter=PostgresEra]
    module TenantProvisioning
      USAGE = "usage: hecks deploy provision <domain-directory> <slug> --domain=NAME --realm=NAME " \
              "--schema=NAME --database=NAME [--adapter=PostgresEra]"

      # The chapters that must boot together for a tenant to be declared and registered.
      CHAPTER_FILES = %w[deploy/bluebook/deploy.bluebook deploy/bluebook/deploy.hecksagon
                         tenancy/bluebook/tenancy.bluebook tenancy/bluebook/tenancy.hecksagon].freeze

      module_function

      # Provisions the tenant and prints what it wrote and confirmed.
      #
      # @param argv [Array<String>] the domain directory, the tenant's slug, then the flags
      # @param root [String] unused: the chapters are read from the library
      # @return [Integer] 0
      # @raise [SystemExit] with the reason on stderr when the shape is invalid, provisioning is
      #   refused, or the tenant never registers
      def main(argv, **)
        argv = argv.dup
        directory = argv.shift
        slug      = argv.shift
        (directory && slug) or abort USAGE

        options = parse(argv)
        domain_directory = File.expand_path(directory)
        File.directory?(domain_directory) or abort "no such domain directory: #{domain_directory}"

        dispatcher = provision(slug, options, domain_directory)
        confirm(dispatcher, slug, options, domain_directory)
        0
      end

      # @param argv [Array<String>] the flags after the slug
      # @return [Hash{Symbol => String}] `domain`, `realm`, `schema`, `database` and `adapter`
      # @raise [SystemExit] when a required flag is missing
      def parse(argv)
        options = { adapter: "PostgresEra" }
        OptionParser.new do |parser|
          parser.on("--domain=NAME")   { |v| options[:domain] = v }
          parser.on("--realm=NAME")    { |v| options[:realm] = v }
          parser.on("--schema=NAME")   { |v| options[:schema] = v }
          parser.on("--database=NAME") { |v| options[:database] = v }
          parser.on("--adapter=NAME")  { |v| options[:adapter] = v }
        end.parse!(argv)

        %i[domain realm schema database].each do |flag|
          options[flag] or abort "hecks deploy provision needs --#{flag}"
        end
        options
      end

      # Boots Deploy and Tenancy together, validates the declared shape with a dry run of
      # `Tenant.Provision` (nothing is recorded), then dispatches it: the record is created once,
      # its policy writes the overlay through the `TenantProvisioning` port, and `TenantProvisioned`
      # reaches Tenancy. The port answers `TenantProvisioned` or `ProvisioningRefused` and never
      # raises, so the record's status says which.
      #
      # @param slug [String] the tenant's slug
      # @param options [Hash] the parsed flags
      # @param domain_directory [String] the domain's directory
      # @return [Hecks::Runtime::Dispatcher] the dispatcher both chapters share
      # @raise [SystemExit] when the declared shape is refused, or provisioning is refused
      def provision(slug, options, domain_directory)
        lib_hecks  = File.expand_path("..", __dir__)
        dispatcher = Hecks.boot_files(CHAPTER_FILES.map { |file| File.join(lib_hecks, file) }, install_doors: false)
        facts = {
          slug:      { value: slug },
          domain:    { value: options[:domain] },
          realm:     { value: options[:realm] },
          schema:    { value: options[:schema] },
          database:  { value: options[:database] },
          adapter:   { value: options[:adapter] },
          directory: { value: domain_directory }
        }

        begin
          dispatcher.dry_run?("Deploy::Tenant.Provision", **facts)
          dispatcher.dispatch("Deploy::Tenant.Provision", to: slug, with: facts)
        rescue *Hecks::Runtime::DOMAIN_REFUSALS => e
          abort "tenant #{slug.inspect} is invalid: #{e.message}"
        end

        tenant = dispatcher.registry.bluebook("Deploy").aggregate("Tenant")
        record = dispatcher.registry.repository("Deploy", tenant).find(slug)
        refused = record&.state&.dig(:refusal)
        refused = refused[:value] if refused.is_a?(Hash)
        record&.state&.dig(:status) == "refused" and
          abort "provisioning #{slug.inspect} was refused: #{refused}"

        puts "wrote #{File.join(domain_directory, "environments", "#{slug}.world")}"
        dispatcher
      end

      # Boots the domain under the tenant's overlay (which also provisions the schema, since
      # `PostgresEra#connect_for` runs an idempotent `CREATE SCHEMA`), checks every bluebook of
      # the registry is tenant capable, and confirms the tenant by query.
      #
      # @param dispatcher [Hecks::Runtime::Dispatcher] the shared dispatcher
      # @param slug [String] the tenant's slug
      # @param options [Hash] the parsed flags
      # @param domain_directory [String] the domain's directory
      # @return [void]
      # @raise [SystemExit] when the tenant was never registered in Tenancy
      def confirm(dispatcher, slug, options, domain_directory)
        target = Hecks.boot(domain_directory, environment: slug, install_doors: false)
        puts "booted #{options[:domain]} for tenant #{slug.inspect} under realm #{options[:realm].inspect}"

        target.registry.bluebooks.each_key do |name|
          Hecks::Runtime::TenantCheck.refuse_unless_tenant_capable!(target.registry, name)
        end

        # A refused reaction never raises, so the record itself is the proof.
        tenant = dispatcher.registry.repository("Tenancy", dispatcher.registry.bluebook("Tenancy").aggregate("Tenant"))
                           .find(slug)
        tenant or abort "provisioning succeeded but #{slug.inspect} was never registered in Tenancy — " \
                        "check registry.reaction_log for a silently refused Register"

        puts "#{options[:domain]} is tenant_capable? for #{slug.inspect} — registered under realm #{options[:realm].inspect}"
      end
    end
  end
end
