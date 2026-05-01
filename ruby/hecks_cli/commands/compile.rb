# Hecks CLI: compile command
#
# Compiles the Hecks framework into a single self-contained binary.
# The output is a bundled Ruby script with all source concatenated
# in load order, executable without any require_relative.
#
#   hecks compile                        # => ./hecks_v0
#   hecks compile --output my_binary     # => ./my_binary
#   hecks compile --plan                 # show what would be compiled
#
Hecks::CLI.handle(:compile) do |inv|
  require "hecks/compiler"

  compiler = Hecks::Compiler::BinaryCompiler.new

  if options[:plan]
    plan = compiler.plan
    say "Compilation plan:", :cyan
    say "  Lib root: #{plan[:lib_root]}"
    say "  Files: #{plan[:file_count]}"
    plan[:files].first(20).each { |f| say "    #{f}" }
    say "    ... (#{plan[:file_count] - 20} more)" if plan[:file_count] > 20
    next
  end

  output = options[:output] || "hecks_v0"
  say "Compiling Hecks v0...", :cyan

  path = compiler.compile(output: output)
  size_kb = (File.size(path) / 1024.0).round(1)
  plan = compiler.plan

  say "Compiled Hecks v0:", :green
  say "  Output: #{path}"
  say "  Size: #{size_kb} KB"
  say "  Files: #{plan[:file_count]} source files bundled"
  say ""
  say "Run with:", :cyan
  say "  ./#{File.basename(path)} boot examples/pizzas"
  say "  ./#{File.basename(path)} self-test"
  say "  ./#{File.basename(path)} version"
end
