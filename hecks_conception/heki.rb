# Heki — Binary record storage for Winter's brain
#
# Projected from: nursery/heki/heki.bluebook (2026.04.11.1)
# Aggregates: Store, Record, Codec
# Policy: CompressOnWrite (RecordWritten → Compress)
#
# Usage:
#   require_relative "heki"
#   store = Heki.store("pulse")                    # CreateStore
#   Heki.append(store, { "beats" => 1 })           # AppendRecord → Compress
#   Heki.upsert(store, { "beats" => 2 })           # UpsertSingleton → Compress
#   records = Heki.read(store)                     # Decompress → ReadRecord
#   Heki.find(store, id)                           # ReadRecord by ID
#   Heki.delete(store, id)                         # DeleteRecord

require "zlib"
require "securerandom"
require "time"

module Heki
  MAGIC = "HEKI"
  COMPRESSION = Zlib::BEST_SPEED
  INFO_DIR = File.expand_path("information", __dir__)

  # -- Codec: Decompress --
  def self.read(path)
    return {} unless File.exist?(path)
    data = File.binread(path)
    return {} unless data[0..3] == MAGIC
    Marshal.load(Zlib::Inflate.inflate(data[8..]))
  end

  # -- Codec: Compress --
  def self.write(path, records)
    blob = Zlib::Deflate.deflate(Marshal.dump(records), COMPRESSION)
    File.binwrite(path, MAGIC + [records.size].pack("N") + blob)
  end

  # -- Store: CreateStore --
  def self.store(name)
    File.join(INFO_DIR, "#{name}.heki")
  end

  # -- Store: AppendRecord --
  def self.append(path, attrs)
    records = read(path)
    id = SecureRandom.uuid
    now = Time.now.iso8601
    record = { "id" => id, "created_at" => now, "updated_at" => now }.merge(attrs)
    records[id] = record
    write(path, records)
    record
  end

  # -- Store: UpsertSingleton --
  def self.upsert(path, attrs)
    records = read(path)
    now = Time.now.iso8601
    _id, record = records.first
    if record
      attrs.each { |k, v| record[k] = v }
      record["updated_at"] = now
    else
      id = SecureRandom.uuid
      record = { "id" => id, "created_at" => now, "updated_at" => now }.merge(attrs)
      records[id] = record
    end
    write(path, records)
    record
  end

  # -- Record: ReadRecord (by ID) --
  def self.find(path, id)
    read(path)[id]
  end

  # -- Record: DeleteRecord --
  def self.delete(path, id)
    records = read(path)
    removed = records.delete(id)
    write(path, records) if removed
    removed
  end

  # -- Convenience: count --
  def self.count(path)
    read(path).size
  end

  # -- Convenience: all values --
  def self.all(path)
    read(path).values
  end

  # -- Convenience: latest record --
  def self.latest(path)
    read(path).values.max_by { |r| r["updated_at"].to_s }
  end
end
