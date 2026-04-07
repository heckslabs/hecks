#!/usr/bin/env ruby
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "__GEM__"

command = ARGV.shift

case command
when "serve", "ui"
  port = ARGV.find { |arg| arg =~ /^\d+$/ }&.to_i || 9292
  adapter = ARGV.find { |arg| arg =~ /^--adapter=/ }&.then { |arg| arg.split("=").last&.to_sym } || :memory
  __MOD__.reboot(adapter: adapter) if adapter != :memory
  puts "__MOD__ on http://localhost:#{port} (adapter: #{adapter})"
  __MOD__.serve(port: port)
when "console"
  require "irb"
  puts "__MOD__ console (memory adapter)"
  IRB.start
when "info"
  puts "__MOD__"
  puts "  Adapter: #{__MOD__.config[:adapter]}"
  puts "  Events:  #{__MOD__.events.size}"
  __MOD__.domain_info.each do |name, info|
    puts "  #{name}: #{info[:count]} records, #{info[:commands].size} commands"
    info[:ports].each { |role, methods| puts "    #{role}: #{methods.join(', ')}" }
  end
else
  puts "__CMD__ — __MOD__ static domain"
  puts ""
  puts "Commands:"
  puts "  __CMD__ serve [PORT] [--adapter=memory|filesystem]   Start HTTP server with UI"
  puts "  __CMD__ ui [PORT]                                     Alias for serve"
  puts "  __CMD__ console                                       IRB with domain loaded"
  puts "  __CMD__ info                                          Show domain config"
end
