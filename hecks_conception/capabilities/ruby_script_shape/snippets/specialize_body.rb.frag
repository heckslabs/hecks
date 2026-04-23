options = { output: nil, diff: false, list: false }
OptionParser.new do |opts|
  opts.banner = "Usage: bin/specialize <target> [options]\n\nTargets:\n  #{Hecks::Specializer.targets.join(', ')}"
  opts.on("-o", "--output PATH", "Write to PATH instead of stdout") { |v| options[:output] = v }
  opts.on("-d", "--diff", "Diff against the target's hand-written .rs") { options[:diff] = true }
  opts.on("-l", "--list", "List known targets") { options[:list] = true }
  opts.on("-h", "--help") { puts opts; exit 0 }
end.parse!

if options[:list]
  puts Hecks::Specializer.targets
  exit 0
end

target = ARGV.shift
if target.nil? || target.empty?
  warn "Missing target. Known: #{Hecks::Specializer.targets.join(', ')}"
  exit 2
end

rust = Hecks::Specializer.emit(target)

if options[:diff]
  target_rs = Hecks::Specializer.target_module(target)::TARGET_RS
  Tempfile.create(["specialize_#{target}_gen", ".rs"]) do |f|
    f.write(rust)
    f.flush
    system "diff", "-u", target_rs.to_s, f.path
  end
elsif options[:output]
  File.write(options[:output], rust)
  warn "wrote #{rust.bytesize} bytes to #{options[:output]}"
else
  print rust
end
