# HecksFilesystemStore
#
# JSON file persistence extension for Hecks domains. Stores each aggregate
# record as a JSON file in data/<aggregate>s/<uuid>.json. Survives process
# restarts without a database. Auto-wires when present in the Gemfile.
#
# Future gem: hecks_filesystem_store
#
#   # Gemfile
#   gem "cats_domain"
#   gem "hecks_filesystem_store"   # auto-wires at boot
#
#   # Or explicitly:
#   app = Hecks.boot(__dir__, adapter: :filesystem)
#
Hecks.describe_extension(:filesystem_store,
  description: "JSON file persistence",
  adapter_type: :driven,
  config: { data_dir: { default: "./data", desc: "Directory for JSON files" } },
  wires_to: :repository)

Hecks.register_extension(:filesystem_store) do |domain_mod, domain, runtime|
  require "json"
  require "time"
  require "fileutils"

  data_dir = ENV.fetch("HECKS_DATA_DIR", "./data")

  domain.aggregates.each do |agg|
    repo = Hecks::FilesystemRepository.new(
      agg.name,
      domain_mod.const_get(agg.name),
      data_dir: data_dir
    )
    runtime.swap_adapter(agg.name, repo)
  end
end

module Hecks
  # Hecks::FilesystemRepository
  #
  # JSON file-based persistence. Each aggregate gets a directory, each
  # record is a JSON file named by ID. Implements the same interface as
  # the memory adapter: find, save, delete, all, count, query, clear.
  #
  class FilesystemRepository
    def initialize(aggregate_name, aggregate_class, data_dir: "./data")
      @aggregate_name = aggregate_name
      @aggregate_class = aggregate_class
      @dir = File.join(data_dir, aggregate_name.downcase + "s")
      FileUtils.mkdir_p(@dir)
    end

    def find(id)
      path = file_path(id)
      return nil unless File.exist?(path)
      deserialize(JSON.parse(File.read(path)))
    end

    def save(obj)
      File.write(file_path(obj.id), JSON.pretty_generate(serialize(obj)))
      obj
    end

    def delete(id)
      path = file_path(id)
      File.delete(path) if File.exist?(path)
    end

    def all
      Dir.glob(File.join(@dir, "*.json")).map do |f|
        deserialize(JSON.parse(File.read(f)))
      end
    end

    def count
      Dir.glob(File.join(@dir, "*.json")).size
    end

    def query(conditions: {}, order_key: nil, order_direction: :asc, limit: nil, offset: nil)
      results = all
      unless conditions.empty?
        results = results.select do |obj|
          conditions.all? do |k, v|
            next false unless obj.respond_to?(k)
            actual = obj.send(k)
            v.is_a?(Hecks::Querying::Operators::Operator) ? v.match?(actual) : actual == v
          end
        end
      end
      if order_key
        results = results.sort_by do |obj|
          val = obj.respond_to?(order_key) ? obj.send(order_key) : nil
          val.nil? ? "" : val
        end
        results = results.reverse if order_direction == :desc
      end
      results = results.drop([offset, 0].max) if offset
      results = results.take([limit, 0].max) if limit
      results
    end

    def clear
      Dir.glob(File.join(@dir, "*.json")).each { |f| File.delete(f) }
    end

    private

    def file_path(id)
      File.join(@dir, "#{id}.json")
    end

    def serialize(obj)
      h = { "id" => obj.id }
      if obj.class.respond_to?(:hecks_attributes)
        obj.class.hecks_attributes.each do |attr|
          h[attr[:name].to_s] = serialize_value(obj.send(attr[:name]))
        end
      end
      h["created_at"] = obj.created_at&.iso8601 if obj.respond_to?(:created_at)
      h["updated_at"] = obj.updated_at&.iso8601 if obj.respond_to?(:updated_at)
      h
    end

    def serialize_value(val)
      case val
      when Array then val.map { |v| serialize_value(v) }
      when ->(v) { v.class.respond_to?(:hecks_attributes) }
        h = {}
        val.class.hecks_attributes.each { |a| h[a[:name].to_s] = serialize_value(val.send(a[:name])) }
        h
      else val
      end
    end

    def deserialize(data)
      attrs = {}
      if @aggregate_class.respond_to?(:hecks_attributes)
        @aggregate_class.hecks_attributes.each do |attr|
          attrs[attr[:name]] = data[attr[:name].to_s]
        end
      end
      obj = @aggregate_class.new(id: data["id"], **attrs)
      if data["created_at"]
        obj.instance_variable_set(:@created_at, Time.parse(data["created_at"])) rescue nil
        obj.instance_variable_set(:@updated_at, Time.parse(data["updated_at"])) rescue nil
      end
      obj
    end
  end
end

# Alias for convenience: adapter: :filesystem
Hecks.extension_registry[:filesystem] = Hecks.extension_registry[:filesystem_store]
