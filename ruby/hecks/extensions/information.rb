# HecksInformation
#
# Binary compressed persistence for beings. Each aggregate type is
# one .heki file — a Zlib-compressed Marshal dump of {id => record}.
# Loaded once into memory, written on mutation.
#
#   Hecks.hecksagon do
#     persistence :information, dir: "information"
#   end
#
# File format:
#   [4 bytes: "HEKI" magic]
#   [4 bytes: record count, big-endian]
#   [rest: Zlib::Deflate of Marshal dump of {String(id) => Hash}]
#
# All reads hit memory. Writes flush to disk.
#
Hecks.describe_extension(:information,
  description: "Binary compressed persistence — one file per aggregate",
  adapter_type: :driven,
  config: { dir: { default: "./information", desc: "Directory for .heki files" } },
  wires_to: :repository)

Hecks.register_extension(:information) do |domain_mod, domain, runtime|
  require "zlib"
  require "fileutils"

  hecksagon = runtime.instance_variable_get(:@hecksagon)
  config = hecksagon&.persistence || {}
  base_dir = config[:dir] || "./information"

  domain.aggregates.each do |agg|
    repo = Hecks::InformationRepository.new(
      agg.name,
      domain_mod.const_get(agg.name),
      dir: base_dir
    )
    runtime.swap_adapter(agg.name, repo)
  end
end

module Hecks
  # Hecks::InformationRepository
  #
  # Binary compressed persistence. One .heki file per aggregate.
  # All records cached in memory after first load.
  #
  #   repo = InformationRepository.new("Pulse", PulseClass, dir: "information")
  #   repo.save(pulse)
  #   repo.find(id)     # memory lookup
  #   repo.all           # cached array
  #
  class InformationRepository
    MAGIC = "HEKI"

    def initialize(aggregate_name, aggregate_class, dir: "./information")
      @aggregate_name = aggregate_name
      @aggregate_class = aggregate_class
      @dir = dir
      @path = File.join(dir, "#{snake(aggregate_name)}.heki")
      @cache = nil
      @dirty = false
      @batch = false
      FileUtils.mkdir_p(dir)
    end

    # Batch mode — accumulate writes, flush once at end.
    #
    #   repo.batch { 1000.times { repo.save(obj) } }
    #
    def batch
      @batch = true
      yield
    ensure
      @batch = false
      flush
    end

    def find(id)
      load_cache
      data = @cache[id.to_s]
      data ? deserialize(data) : nil
    end

    def save(obj)
      load_cache
      @cache[obj.id.to_s] = serialize(obj)
      @dirty = true
      flush unless @batch
      obj
    end

    def delete(id)
      load_cache
      @cache.delete(id.to_s)
      @dirty = true
      flush unless @batch
    end

    def all
      load_cache
      @cache.values.map { |data| deserialize(data) }
    end

    def count
      load_cache
      @cache.size
    end

    def query(conditions: {}, order_key: nil, order_direction: :asc, limit: nil, offset: nil)
      results = all
      unless conditions.empty?
        results = results.select do |obj|
          conditions.all? do |k, v|
            next false unless obj.respond_to?(k)
            actual = obj.send(k)
            v.respond_to?(:match?) ? v.match?(actual) : actual == v
          end
        end
      end
      if order_key
        results = results.sort_by { |obj|
          val = obj.respond_to?(order_key) ? obj.send(order_key) : nil
          val.nil? ? "" : val.to_s
        }
        results = results.reverse if order_direction == :desc
      end
      results = results.drop([offset, 0].max) if offset
      results = results.take([limit, 0].max) if limit
      results
    end

    def clear
      @cache = {}
      @dirty = true
      flush
    end

    # Disk size in bytes
    def disk_size
      File.exist?(@path) ? File.size(@path) : 0
    end

    private

    def load_cache
      return if @cache
      if File.exist?(@path)
        raw = File.binread(@path)
        magic = raw[0, 4]
        raise "Not a HEKI file: #{@path}" unless magic == MAGIC
        count = raw[4, 4].unpack1("N")
        blob = raw[8..]
        @cache = Marshal.load(Zlib::Inflate.inflate(blob))
      else
        @cache = {}
      end
    end

    def flush
      return unless @dirty
      blob = Zlib::Deflate.deflate(Marshal.dump(@cache), Zlib::BEST_SPEED)
      File.binwrite(@path, MAGIC + [@cache.size].pack("N") + blob)
      @dirty = false
    end

    def snake(name)
      name.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
           .gsub(/([a-z\d])([A-Z])/, '\1_\2')
           .downcase
    end

    def serialize(obj)
      hash = { "id" => obj.id }
      if obj.class.respond_to?(:hecks_attributes)
        obj.class.hecks_attributes.each do |attr|
          hash[attr[:name].to_s] = serialize_value(obj.send(attr[:name]))
        end
      end
      hash["created_at"] = obj.created_at&.iso8601 if obj.respond_to?(:created_at)
      hash["updated_at"] = obj.updated_at&.iso8601 if obj.respond_to?(:updated_at)
      hash
    end

    def serialize_value(val)
      case val
      when Array then val.map { |item| serialize_value(item) }
      when Hecks::Persistence::CollectionProxy then val.map { |item| serialize_value(item) }
      when Hecks::Persistence::CollectionItem then serialize_value(val.__raw__)
      when ->(v) { v.class.respond_to?(:hecks_attributes) }
        result = {}
        val.class.hecks_attributes.each { |attr| result[attr.name.to_s] = serialize_value(val.send(attr.name)) }
        result
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
