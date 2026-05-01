Hecks::CLI.register_command(:smoke, "Run smoke tests on all examples") do
  require "open3"
  output, status = Open3.capture2e("bundle", "exec", "rspec", "--pattern", "hecks_smoke/spec/**/*_spec.rb", "--format", "documentation")
  puts output
  exit(status.exitstatus)
end
