# seed_linux_merge.rb
#
# Merges worker fragments into a single file_node.heki.
# Also seeds mount and shell_session.
#
# Usage: ruby -I../lib seed_linux_merge.rb <fragment1> <fragment2> ...

require "zlib"
require "etc"
require "securerandom"
require "time"

MAGIC = "HEKI"
INFO_DIR = File.expand_path("../hecks_being/winter/information", __dir__)
NOW = Time.now.iso8601

# ============================================================
# MERGE FILE NODES
# ============================================================

all_records = {}
ARGV.each do |fragment|
  records = Marshal.load(File.binread(fragment))
  all_records.merge!(records)
end

# Convert path-keyed hash to id-keyed hash for .heki format
cache = {}
all_records.each do |path, attrs|
  id = SecureRandom.uuid
  hash = { "id" => id }
  attrs.each { |k, v| hash[k.to_s] = v }
  hash["created_at"] = NOW
  hash["updated_at"] = NOW
  cache[id] = hash
end

blob = Zlib::Deflate.deflate(Marshal.dump(cache), Zlib::BEST_SPEED)
File.binwrite(File.join(INFO_DIR, "file_node.heki"), MAGIC + [cache.size].pack("N") + blob)
puts "file_node: #{cache.size} records, #{(File.size(File.join(INFO_DIR, 'file_node.heki')) / 1024.0).round(1)} KB"

# ============================================================
# MOUNTS
# ============================================================

mount_cache = {}
`mount`.each_line do |line|
  next unless line =~ /^(\S+)\s+on\s+(\S+)\s+\(([^)]+)\)/
  device, mountpoint, opts = $1, $2, $3
  fs_type = opts.split(",").first.strip
  options = opts.split(",").map(&:strip)
  total = 0
  if mountpoint == "/" || mountpoint.start_with?("/Users")
    df = `df -k '#{mountpoint}' 2>/dev/null`.lines.last
    total = (df.split[1].to_i * 1024) rescue 0 if df
  end
  id = SecureRandom.uuid
  mount_cache[id] = {
    "id" => id, "device" => device, "mountpoint" => mountpoint,
    "fs_type" => fs_type, "options" => options,
    "total_bytes" => total, "used_bytes" => 0,
    "created_at" => NOW, "updated_at" => NOW
  }
end

blob = Zlib::Deflate.deflate(Marshal.dump(mount_cache), Zlib::BEST_SPEED)
File.binwrite(File.join(INFO_DIR, "mount.heki"), MAGIC + [mount_cache.size].pack("N") + blob)
puts "mount: #{mount_cache.size} records"

# ============================================================
# SHELL SESSION
# ============================================================

session_cache = {}
id = SecureRandom.uuid
session_cache[id] = {
  "id" => id, "shell_type" => ENV["SHELL"] || "zsh",
  "cwd" => Dir.pwd, "user" => Etc.getlogin,
  "env" => [], "history" => [], "last_exit_code" => 0,
  "created_at" => NOW, "updated_at" => NOW
}

blob = Zlib::Deflate.deflate(Marshal.dump(session_cache), Zlib::BEST_SPEED)
File.binwrite(File.join(INFO_DIR, "shell_session.heki"), MAGIC + [session_cache.size].pack("N") + blob)
puts "shell_session: 1 record"

# Empty pipe and process
[["pipe", 0], ["process", 0]].each do |name, _|
  blob = Zlib::Deflate.deflate(Marshal.dump({}), Zlib::BEST_SPEED)
  File.binwrite(File.join(INFO_DIR, "#{name}.heki"), MAGIC + [0].pack("N") + blob)
end
puts "pipe: 0 records"
puts "process: 0 records"

# Cleanup fragments
ARGV.each { |f| File.delete(f) if File.exist?(f) }

# Total
total = Dir[File.join(INFO_DIR, "*.heki")].sum { |f| File.size(f) }
puts "\nTotal information: #{(total / 1024.0).round(1)} KB"
