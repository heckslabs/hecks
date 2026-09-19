# frozen_string_literal: true

require "fileutils"

module Hecks
  module Adapters
    # THE IMPERATIVE HALF of provisioning a tenant, pulled out of
    # `bin/project_tenant` and behind a real driven port
    # (`Deploy::Tenant.port "TenantProvisioning"`) instead — the same
    # hexagonal reasoning `GithubChecks` already gives for its own
    # port: real, impure, side-effecting work (file IO, booting a
    # process) belongs in an adapter, not in a bare script or a command
    # handler. `Deploy::Tenant`'s own `asks "Provision"` operation calls
    # `#provision` and turns whatever it returns into `TenantProvisioned`,
    # or whatever it raises into `ProvisioningRefused` — see
    # `PortOperationInterpreter#ask`'s own "every failure is an answer"
    # comment for why nothing here needs its own rescue.
    #
    # RETURNS A HASH SHAPED LIKE `Tenancy::Tenant.Register`'s OWN
    # ARGUMENTS, on purpose — `tenancy.hecksagon`'s own `translates`
    # reaction forwards an answered event's payload verbatim, so this
    # adapter's own return value IS the translation from Deploy's
    # vocabulary into Tenancy's, decided here rather than in a mapping
    # layer neither side could see into.
    class TenantProvisioner
      def initialize(aggregate: nil, settings: {}, root: nil); end

      def provision(slug:, domain:, realm:, schema:, database:, adapter:)
        domain_directory = File.expand_path(domain[:value] || domain, Dir.pwd)

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

        dispatcher = Hecks.boot(domain_directory, environment: (slug[:value] || slug), install_facade: false)
        dispatcher.registry.bluebooks.each_key do |name|
          Runtime::TenantCheck.refuse_unless_tenant_capable!(dispatcher.registry, name)
        end

        { slug: slug, domain: domain, realm: realm, schema: schema }
      end
    end
  end
end
