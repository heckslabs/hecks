# __DOMAIN_MODULE__::Adapters::FilesystemRepository
#
# JSON file-based persistence adapter. Each aggregate gets a directory,
# each record is a JSON file named by ID. No database dependency,
# survives restarts. Suitable for development, small deployments,
# and as a failover target when the database is unavailable.
#
#   repo = FilesystemRepository.new("Pizza", data_dir: "./data")
#   repo.save(pizza)   # writes data/pizzas/uuid.json
#   repo.find(id)      # reads data/pizzas/uuid.json
#   repo.all           # reads all JSON files in data/pizzas/

require "json"
require "time"
require "fileutils"

module __DOMAIN_MODULE__
  module Adapters
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
              if v.is_a?(__DOMAIN_MODULE__::Runtime::Operators::Operator)
                v.match?(actual)
              else
                actual == v
              end
            end
          end
        end
        if order_key
          results = results.sort_by { |obj| val = obj.respond_to?(order_key) ? obj.send(order_key) : nil; val.nil? ? "" : val }
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
        if obj.class.respond_to?(:domain_attributes)
          obj.class.domain_attributes.each do |attr|
            val = obj.send(attr[:name])
            h[attr[:name].to_s] = serialize_value(val)
          end
        end
        h["created_at"] = obj.created_at&.iso8601 if obj.respond_to?(:created_at)
        h["updated_at"] = obj.updated_at&.iso8601 if obj.respond_to?(:updated_at)
        h
      end

      def serialize_value(val)
        case val
        when Array then val.map { |v| serialize_value(v) }
        when ->(v) { v.class.respond_to?(:domain_attributes) }
          h = {}
          val.class.domain_attributes.each { |a| h[a[:name].to_s] = serialize_value(val.send(a[:name])) }
          h
        else val
        end
      end

      def deserialize(data)
        attrs = {}
        if @aggregate_class.respond_to?(:domain_attributes)
          @aggregate_class.domain_attributes.each do |attr|
            raw = data[attr[:name].to_s]
            attrs[attr[:name]] = raw
          end
        end
        obj = @aggregate_class.new(id: data["id"], **attrs)
        if data["created_at"] && obj.respond_to?(:instance_variable_set)
          obj.instance_variable_set(:@created_at, Time.parse(data["created_at"])) rescue nil
          obj.instance_variable_set(:@updated_at, Time.parse(data["updated_at"])) rescue nil
        end
        obj
      end
    end
  end
end
