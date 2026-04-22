# examples/shell_adapter/shell_demo.rb
#
# End-to-end demo: boot the ShellDemo domain (which has an :echo_args
# and :list_files shell adapter declared in its hecksagon), then
# dispatch both through runtime.shell.
#
# Run:  ruby -Ilib examples/shell_adapter/shell_demo.rb

require "hecks"

runtime = Hecks.boot(File.expand_path(__dir__))

puts "--- :echo_args ---"
result = runtime.shell(:echo_args, msg: "hello")
puts "output:      #{result.output.inspect}"
puts "exit_status: #{result.exit_status}"

puts ""
puts "--- :list_files (current dir) ---"
listing = runtime.shell(:list_files, dir: __dir__)
puts "first 3 entries: #{listing.output.first(3).inspect}"
puts "total entries:   #{listing.output.size}"
