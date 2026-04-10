# seed_linux_worker.rb
#
# Walks a single directory tree and writes a Marshal fragment.
# Usage: ruby seed_linux_worker.rb <root_dir> <output_path>

require "etc"
require "fileutils"
require "time"

root = ARGV[0]
output = ARGV[1]
skip = %w[.git node_modules tmp vendor .bundle]

records = {}

queue = [root]
while (dir = queue.shift)
  next unless File.exist?(dir)
  begin
    s = File.stat(dir)
    records[dir] = {
      path: dir,
      name: File.basename(dir),
      kind: "directory",
      parent_path: File.dirname(dir),
      size: s.size,
      permissions: sprintf("%o", s.mode & 0o7777),
      owner: (Etc.getpwuid(s.uid)&.name rescue s.uid.to_s),
      group: (Etc.getgrgid(s.gid)&.name rescue s.gid.to_s),
      modified_at: s.mtime.iso8601
    }
  rescue
    next
  end

  begin
    Dir.children(dir).sort.each do |child|
      next if skip.include?(child)
      full = File.join(dir, child)
      if File.directory?(full)
        queue << full
      else
        begin
          s = File.stat(full)
          records[full] = {
            path: full,
            name: child,
            kind: "file",
            parent_path: dir,
            size: s.size,
            permissions: sprintf("%o", s.mode & 0o7777),
            owner: (Etc.getpwuid(s.uid)&.name rescue s.uid.to_s),
            group: (Etc.getgrgid(s.gid)&.name rescue s.gid.to_s),
            modified_at: s.mtime.iso8601
          }
        rescue
          next
        end
      end
    end
  rescue
    next
  end
end

File.binwrite(output, Marshal.dump(records))
$stderr.puts "#{File.basename(root)}: #{records.size} nodes"
