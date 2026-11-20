require "base64"
require "digest"

module Hecks
  module Projector
    module Exporter
      # The wasm components a domain's hecksagon wires to its ports, for the IR's `components`
      # key, in the shape of its `plugins`: the module rides in the IR with its SHA-256, so a
      # deploy that ships the IR ships the component, and the host loads it by that digest. Each
      # entry carries the grant the host cuts for it: the secrets, imports and hosts it declares.
      module Components
        # Every component a domain's hecksagon binds, by adapter name.
        #
        # @param registry [Runtime::Registry] the loaded registry
        # @param domain_name [String] the domain whose hecksagon is read
        # @return [Array<Hash{String => Object}>] `"adapter"`, `"port"`, `"verb"`, `"runs"`,
        #   `"sha256"`, `"module"` (the module's bytes, base64), `"secrets"`, `"imports"` and
        #   `"hosts"`; empty when the hecksagon binds none, or there is no hecksagon
        def components(registry, domain_name)
          binds = registry.hecksagon(domain_name)&.binds || []
          wired = binds.filter_map { |bind| component_bind(registry, bind) }
          wired.uniq { |adapter, _| adapter.name }.sort_by { |adapter, _| adapter.name }
               .map { |adapter, bind| component_hash(adapter, bind) }
        end

        # A bind's adapter with the bind, when that adapter is a component.
        def component_bind(registry, bind)
          adapter = registry.adapters[bind.adapter]
          [adapter, bind] if adapter&.component?
        end

        def component_hash(adapter, bind)
          bytes = File.binread(adapter.plugin_path)
          {
            "adapter" => adapter.name, "port" => adapter.port, "verb" => bind.verb, "runs" => adapter.runs,
            "sha256" => Digest::SHA256.hexdigest(bytes), "module" => Base64.strict_encode64(bytes),
            "secrets" => (adapter.secrets || []).map(&:to_s), "imports" => adapter.granted_imports,
            "hosts" => adapter.granted_hosts
          }
        end
      end
    end
  end
end
