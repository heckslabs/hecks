require_relative "routing"

module Hecks
  module Projections
    module Deploy
      module Fargate
        module Containers
          # Reads and checks the container settings of a world. Extended onto `Containers`, which
          # supplies the structs and the key lists.
          module Reading
            include Routing

            private

            def extra_containers(settings)
              entries = Check.hashes!(settings.fetch(:containers, []), "containers", allowed:  CONTAINER_KEYS,
                                                                                     required: [:name, :repository])
              entries.map { |entry| extra_container(entry) }
            end

            def domain_container(setting, infra_name:, port:, ids:)
              given = setting ? Check.hash!(setting, "domain_container", allowed: DOMAIN_KEYS) : {}
              name = Check.resource_name!(given.fetch(:name, infra_name), "domain_container name")
              repository = Check.resource_name!(given.fetch(:repository, infra_name), "domain_container repository")
              Container.new(
                name: name, repository_id: ids.fetch(:ecr_repository), repository_name: repository,
                tag_parameter: Check.logical_id!(given.fetch(:image_tag_parameter, "ImageTag"),
                                                 "domain_container image_tag_parameter"),
                port: port, health_path: health_path(given, "domain_container"), env: {}, secrets: {},
                essential: domain_essential(given), target_group_id: ids.fetch(:target_group)
              )
            end

            def domain_essential(given)
              given.key?(:essential) ? Check.boolean!(given[:essential], "domain_container essential") : nil
            end

            def extra_container(entry)
              name = Check.resource_name!(entry.fetch(:name), "containers name")
              where = "containers[#{name}]"
              Container.new(
                name: name, repository_name: Check.resource_name!(entry.fetch(:repository), "#{where} repository"),
                **extra_container_ids(entry, where, Yaml.camel(name)), **extra_container_settings(entry, where)
              )
            end

            def extra_container_ids(entry, where, base)
              {
                repository_id:   Check.logical_id!(entry.fetch(:repository_id, "#{base}Repository"), "#{where} repository_id"),
                target_group_id: Check.logical_id!(entry.fetch(:target_group_id, "#{base}TargetGroup"),
                                                   "#{where} target_group_id"),
                tag_parameter:   Check.logical_id!(entry.fetch(:image_tag_parameter, "#{base}ImageTag"),
                                                   "#{where} image_tag_parameter")
              }
            end

            def extra_container_settings(entry, where)
              {
                port: optional_port(entry, where), health_path: health_path(entry, where),
                env: Check.map!(entry.fetch(:env, {}), "#{where} env"),
                secrets: Check.map!(entry.fetch(:secrets, {}), "#{where} secrets"),
                cpu: optional_size(entry, :cpu, where), memory: optional_size(entry, :memory, where),
                essential: Check.boolean!(entry.fetch(:essential, true), "#{where} essential")
              }
            end

            def optional_port(entry, where)
              entry.key?(:port) ? Check.integer!(entry[:port], "#{where} port", range: 1..65_535) : nil
            end

            def optional_size(entry, key, where)
              entry.key?(key) ? Check.integer!(entry[key], "#{where} #{key}", range: 1..1_000_000) : nil
            end

            def health_path(entry, where)
              path = entry.fetch(:health_path, "/").to_s
              return path if path.start_with?("/")

              raise ArgumentError, "#{where} health_path must start with /, got #{path.inspect}"
            end
          end
        end
      end
    end
  end
end
