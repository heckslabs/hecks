# frozen_string_literal: true

require "fileutils"

module Hecks
  module Adapters
    # THE IMPERATIVE HALF of provisioning a tenant, pulled out of
    # `bin/project_tenant` and behind a real driven port
    # (`Deploy::Tenant.port "TenantProvisioning"`) instead — the same
    # hexagonal reasoning `GithubChecks` already gives for its own
    # port: real, impure, side-effecting work (writing the overlay
    # file) belongs in an adapter, not in a bare script or a command
    # handler. `Deploy::Tenant`'s own `asks "Provision"` operation calls
    # `#provision` and turns whatever it returns into `TenantProvisioned`,
    # or whatever it raises into `ProvisioningRefused` — see
    # `PortOperationInterpreter#ask`'s own "every failure is an answer"
    # comment for why nothing here needs its own rescue.
    #
    # DELIBERATELY DOES NOT BOOT THE TARGET DOMAIN — that step (proving
    # it boots for real, running the tenant_capable? gate) stays in
    # `bin/project_tenant` itself, called AFTER this operation answers,
    # not nested inside it. Booting a whole domain from inside an
    # adapter method that is itself running mid-dispatch (this port
    # operation) is a real, separate concern from writing one file, and
    # keeping the two apart avoids a nested `Hecks.boot` call ever
    # running inside another boot's own dispatch call stack.
    #
    # RETURNS A HASH SHAPED LIKE `Tenancy::Tenant.Register`'S OWN
    # ARGUMENTS, on purpose — `tenancy.hecksagon`'s own `translates`
    # reaction forwards an answered event's payload verbatim, so this
    # adapter's own return value IS the translation from Deploy's
    # vocabulary into Tenancy's, decided here rather than in a mapping
    # layer neither side could see into.
    class TenantProvisioner
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # `directory:` IS REQUIRED, NOT DERIVED FROM `domain` — a real,
      # confirmed bug found only under CI's own real-Postgres suite: a
      # domain's own DECLARED NAME (`domain`, e.g. "Scratch") is not a
      # filesystem path, and File.expand_path(domain, Dir.pwd) silently
      # resolved to the wrong directory (relative to whatever the
      # RUNNING PROCESS' own cwd happened to be) whenever the CLI's own
      # `--domain=` value didn't happen to equal its own directory
      # argument by coincidence. `bin/project_tenant` passes its own
      # real `domain_directory` local straight through.

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
