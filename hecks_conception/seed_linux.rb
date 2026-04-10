# seed_linux.rb
#
# Seeds Winter's LinuxSystem organ with the current machine state:
# - Hecks project file tree (FileNodes)
# - Active mounts
# - Current shell session
#
# Usage: ruby -I../lib seed_linux.rb

require "hecks"
require "hecks/extensions/information"
require "hecks_being"
require "etc"

winter = HecksBeing.boot
winter.organs.each_key { |n| winter.silence(n) rescue nil }

rt = winter.graft("LinuxSystem")
puts

HECKS_ROOT = File.expand_path("../..", __dir__)
NOW = Time.now.iso8601

Hecks.current_role = "Shell"
Hecks.actor = OpenStruct.new(role: "Shell")

# Get the FileNode repo for batch mode
file_node_repo = LinuxSystemBluebook::FileNode::Commands::Discover.repository

# ============================================================
# FILE TREE — discover the hecks project
# ============================================================

def stat_node(path)
  s = File.stat(path)
  owner = (Etc.getpwuid(s.uid)&.name rescue s.uid.to_s)
  group = (Etc.getgrgid(s.gid)&.name rescue s.gid.to_s)
  {
    path: path,
    name: File.basename(path),
    kind: s.directory? ? "directory" : (s.symlink? ? "symlink" : "file"),
    parent_path: File.dirname(path),
    size: s.size,
    permissions: sprintf("%o", s.mode & 0o7777),
    owner: owner,
    group: group,
    modified_at: s.mtime.iso8601
  }
rescue
  nil
end

# Walk the tree, skip .git and node_modules
file_count = 0
dir_count = 0

file_node_repo.batch do
  queue = [HECKS_ROOT]
  while (dir = queue.shift)
    info = stat_node(dir)
    next unless info

    LinuxSystemBluebook::FileNode.discover(**info)
    dir_count += 1

    children = Dir.children(dir).sort

    # Skip heavy directories
    skip = %w[.git node_modules tmp vendor .bundle]
    walkable = children.reject { |c| skip.include?(c) }

    walkable.each do |child|
      full = File.join(dir, child)
      if File.directory?(full)
        queue << full
      else
        ci = stat_node(full)
        next unless ci
        LinuxSystemBluebook::FileNode.discover(**ci)
        file_count += 1
      end
    end
  end
end

puts "  FileNodes: #{dir_count} dirs, #{file_count} files"

# ============================================================
# MOUNTS
# ============================================================

Hecks.current_role = "Root"
Hecks.actor = OpenStruct.new(role: "Root")

mount_count = 0
`mount`.each_line do |line|
  # /dev/disk1s1 on / (apfs, local, journaled)
  next unless line =~ /^(\S+)\s+on\s+(\S+)\s+\(([^)]+)\)/
  device, mountpoint, opts = $1, $2, $3
  fs_type = opts.split(",").first.strip
  options = opts.split(",").map(&:strip)

  # Get usage for real mounts
  total = 0
  if mountpoint == "/" || mountpoint.start_with?("/Users")
    df = `df -k '#{mountpoint}' 2>/dev/null`.lines.last
    if df
      parts = df.split
      total = (parts[1].to_i * 1024) rescue 0
    end
  end

  LinuxSystemBluebook::Mount.mount_filesystem(
    device: device,
    mountpoint: mountpoint,
    fs_type: fs_type,
    options: options,
    total_bytes: total
  )
  mount_count += 1
end

puts "  Mounts: #{mount_count}"

# ============================================================
# SHELL SESSION
# ============================================================

Hecks.current_role = "User"
Hecks.actor = OpenStruct.new(role: "User")

LinuxSystemBluebook::ShellSession.open_session(
  shell_type: ENV["SHELL"] || "zsh",
  cwd: Dir.pwd,
  user: Etc.getlogin
)

puts "  ShellSession: #{Etc.getlogin}@#{ENV['SHELL']}"

# Re-express
winter.organs.each_key { |n| winter.express(n) rescue nil }

# ============================================================
# REPORT
# ============================================================

info_dir = File.join(HECKS_ROOT, "hecks_being", "winter", "information")
%w[file_node process pipe mount shell_session].each do |name|
  heki = File.join(info_dir, "#{name}.heki")
  if File.exist?(heki)
    raw = File.binread(heki)
    count = raw[4, 4].unpack1("N")
    size = File.size(heki)
    puts "  #{name.ljust(20)} #{count} records  #{(size / 1024.0).round(1)} KB"
  else
    puts "  #{name.ljust(20)} -"
  end
end
