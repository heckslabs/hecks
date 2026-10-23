require_relative "../naming"

module Hecks
  module Projections
    # A starting `.world` for the domains a registry holds, read off the settings each bound
    # adapter declares: its fields with their defaults, and its secrets.
    #
    # A secret is written as an environment lookup and never as a value. A field with a default is
    # a comment, because the default already applies when the world gives none. A field without
    # one is a comment too, so nothing loads with a made-up value. It reads a whole registry, so
    # it is a plain module and not a registered `Projector` target, and it changes nothing.
    module WorldSkeleton
      # What stands in for the skeleton when no bound adapter declares anything.
      NONE = "# No world is needed: no bound adapter declares a setting or a secret.\n".freeze

      module_function

      # @param registry [Runtime::Registry] a registry whose hecksagons and adapters are loaded
      # @return [String] one `Hecks.world` block per domain that binds an adapter with settings,
      #   or `NONE` when no domain does
      def call(registry:)
        blocks = registry.hecksagons.values.filter_map { |hecksagon| world_for(registry, hecksagon) }
        blocks.empty? ? NONE : blocks.join("\n")
      end

      # @api private
      def world_for(registry, hecksagon)
        sections = sections_for(registry, hecksagon)
        return if sections.empty?

        domain = hecksagon.domain.to_s
        "Hecks.world #{domain.inspect} do\n  realm #{domain.inspect}\n\n#{sections.join("\n")}end\n"
      end

      # @api private
      def sections_for(registry, hecksagon)
        hecksagon.binds.map { |bind| [bind.verb, bind.adapter] }.uniq.filter_map do |verb, name|
          section(hecksagon.domain.to_s, verb, registry.adapters[name])
        end
      end

      # @api private
      def section(domain, verb, adapter)
        return unless adapter && (adapter.fields.any? || adapter.secrets.any?)

        lines = adapter.fields.map { |field| field_line(adapter, field) }
        lines += adapter.secrets.map { |secret| secret_line(domain, secret) }
        "  #{verb}(#{adapter.name.inspect}) do\n#{lines.map { |line| "    #{line}\n" }.join}  end\n"
      end

      # @api private
      def field_line(adapter, field)
        return "# #{field} \"...\"  (no default; set it)" unless adapter.defaults.key?(field)

        "# #{field} #{adapter.defaults[field].inspect}  (the default; uncomment to change it)"
      end

      # @api private
      def secret_line(domain, secret)
        variable = "#{Naming.snake(domain)}_#{secret}".upcase
        "#{secret} ENV.fetch(#{variable.inspect}, \"\")  # secret: set it in the environment"
      end
    end
  end
end
