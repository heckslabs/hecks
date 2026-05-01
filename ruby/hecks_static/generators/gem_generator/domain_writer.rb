# HecksStatic::GemGenerator::DomainWriter
#
# Writes domain artifacts: aggregates, value objects, entities, commands,
# events, policies, specifications, queries, ports, adapters, services.
# Reuses hecks_domain generators with mixin_prefix for static output.
#
module HecksStatic
  class GemGenerator < Hecks::Generator
    module DomainWriter
      include HecksTemplating::NamingHelpers

      DomainGen = Hecks::Generators::Domain
      InfraGen  = Hecks::Generators::Infrastructure

      private

      # Resolves a path relative to root through +Hecks::Utils.safe_path!+,
      # raising +PathTraversalDetected+ if the path escapes root.
      #
      # @param root [String] the output root directory
      # @param *parts [Array<String>] path segments to join before resolving
      # @return [String] the safe absolute path
      def safe_join(root, *parts)
        relative = File.join(*parts)
        Hecks::Utils.safe_path!(root, relative)
      end

      def generate_aggregates(root, gem_name, mod)
        @domain.aggregates.each do |agg|
          agg_dir = safe_join(root, "lib", gem_name, domain_snake_name(agg.name))
          FileUtils.mkdir_p(agg_dir)

          gen = DomainGen::AggregateGenerator.new(agg, domain_module: mod, mixin_prefix: mod)
          agg_source = gen.generate
          autoloads = InfraGen::AutoloadGenerator.new(@domain)
            .aggregate_autoloads(agg, gem_name)
          agg_source = inject_autoloads(agg_source, agg.name, autoloads)
          File.write(File.join(agg_dir, "#{domain_snake_name(agg.name)}.rb"), agg_source)

          write_value_objects(agg, agg_dir, mod)
          write_entities(agg, agg_dir, mod)
          write_commands(agg, agg_dir, mod)
          write_events(agg, agg_dir, mod)
          write_policies(agg, agg_dir, mod)
          write_specifications(agg, agg_dir, mod)
          write_lifecycle(agg, agg_dir, mod)
        end
      end

      def generate_queries(root, gem_name, mod)
        @domain.aggregates.each do |agg|
          next if agg.queries.empty?
          q_dir = safe_join(root, "lib", gem_name, domain_snake_name(agg.name), "queries")
          FileUtils.mkdir_p(q_dir)
          agg.queries.each do |query|
            gen = DomainGen::QueryGenerator.new(query,
              domain_module: mod, aggregate_name: agg.name, mixin_prefix: mod)
            File.write(File.join(q_dir, "#{domain_snake_name(query.name)}.rb"), gen.generate)
          end
        end
      end

      def generate_ports(root, gem_name, mod)
        port_dir = safe_join(root, "lib", gem_name, "ports")
        FileUtils.mkdir_p(port_dir)
        @domain.aggregates.each do |agg|
          gen = InfraGen::PortGenerator.new(agg, domain_module: mod)
          File.write(File.join(port_dir, "#{domain_snake_name(agg.name)}_repository.rb"), gen.generate)
        end
      end

      def generate_adapters(root, gem_name, mod)
        adapter_dir = safe_join(root, "lib", gem_name, "adapters")
        FileUtils.mkdir_p(adapter_dir)
        @domain.aggregates.each do |agg|
          gen = InfraGen::MemoryAdapterGenerator.new(agg,
            domain_module: mod, mixin_prefix: mod)
          File.write(File.join(adapter_dir, "#{domain_snake_name(agg.name)}_memory_repository.rb"), gen.generate)
        end
        template_dir = File.expand_path("../../templates", __dir__)
        source = File.read(File.join(template_dir, "filesystem_adapter.rb"))
        File.write(File.join(adapter_dir, "filesystem_repository.rb"), source.gsub("__DOMAIN_MODULE__", mod))
      end

      def generate_services(root, gem_name, mod)
        return if @domain.services.empty?
        svc_dir = safe_join(root, "lib", gem_name, "services")
        FileUtils.mkdir_p(svc_dir)
        @domain.services.each do |svc|
          gen = DomainGen::ServiceGenerator.new(svc, domain_module: mod)
          File.write(File.join(svc_dir, "#{domain_snake_name(svc.name)}.rb"), gen.generate)
        end
      end

      def inject_autoloads(source, agg_name, autoload_lines)
        return source if autoload_lines.empty?
        lines = source.split("\n")
        class_idx = lines.index { |l| l =~ /class #{agg_name}/ }
        return source unless class_idx
        lines.insert(class_idx + 1, *autoload_lines.map { |l| "    #{l}" })
        lines.join("\n") + "\n"
      end

      def write_value_objects(agg, dir, mod)
        agg.value_objects.each do |vo|
          gen = DomainGen::ValueObjectGenerator.new(vo, domain_module: mod, aggregate_name: agg.name)
          File.write(File.join(dir, "#{domain_snake_name(vo.name)}.rb"), gen.generate)
        end
      end

      def write_entities(agg, dir, mod)
        agg.entities.each do |ent|
          gen = DomainGen::EntityGenerator.new(ent, domain_module: mod, aggregate_name: agg.name)
          File.write(File.join(dir, "#{domain_snake_name(ent.name)}.rb"), gen.generate)
        end
      end

      def write_commands(agg, dir, mod)
        cmd_dir = File.join(dir, "commands")
        FileUtils.mkdir_p(cmd_dir)
        agg.commands.each_with_index do |cmd, i|
          gen = DomainGen::CommandGenerator.new(cmd,
            domain_module: mod, aggregate_name: agg.name,
            aggregate: agg, event: agg.events[i], mixin_prefix: mod)
          File.write(File.join(cmd_dir, "#{domain_snake_name(cmd.name)}.rb"), gen.generate)
        end
      end

      def write_events(agg, dir, mod)
        evt_dir = File.join(dir, "events")
        FileUtils.mkdir_p(evt_dir)
        agg.events.each do |evt|
          gen = DomainGen::EventGenerator.new(evt, domain_module: mod, aggregate_name: agg.name)
          File.write(File.join(evt_dir, "#{domain_snake_name(evt.name)}.rb"), gen.generate)
        end
      end

      def write_policies(agg, dir, mod)
        return if agg.policies.empty?
        pol_dir = File.join(dir, "policies")
        FileUtils.mkdir_p(pol_dir)
        agg.policies.each do |pol|
          gen = DomainGen::PolicyGenerator.new(pol, domain_module: mod, aggregate_name: agg.name)
          File.write(File.join(pol_dir, "#{domain_snake_name(pol.name)}.rb"), gen.generate)
        end
      end

      def write_specifications(agg, dir, mod)
        return if agg.specifications.empty?
        spec_dir = File.join(dir, "specifications")
        FileUtils.mkdir_p(spec_dir)
        agg.specifications.each do |spec|
          gen = DomainGen::SpecificationGenerator.new(spec,
            domain_module: mod, aggregate_name: agg.name, mixin_prefix: mod)
          File.write(File.join(spec_dir, "#{domain_snake_name(spec.name)}.rb"), gen.generate)
        end
      end

      def write_lifecycle(agg, dir, mod)
        return unless agg.lifecycle
        gen = DomainGen::LifecycleGenerator.new(agg.lifecycle,
          domain_module: mod, aggregate_name: domain_constant_name(agg.name))
        File.write(File.join(dir, "lifecycle.rb"), gen.generate)
      end
    end
  end
end
