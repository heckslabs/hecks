# Hecks::CLI smoketest command
#
# Runs verify + specs for all example domains. Each example that
# has a spec/ directory gets its tests run.
#
#   hecks smoketest
#
Hecks::CLI.register_command(:smoketest, "Run all example domain tests") do
  examples_dir = File.join(Dir.pwd, "examples")
  unless File.directory?(examples_dir)
    say "No examples/ directory found", :red
    exit 1
  end

  passed = 0
  failed = 0
  errors = []

  Dir[File.join(examples_dir, "*")].sort.each do |example_dir|
    next unless File.directory?(example_dir)
    name = File.basename(example_dir)

    # Check for spec/ directory
    spec_dir = File.join(example_dir, "spec")
    next unless File.directory?(spec_dir)

    say "#{name}... ", nil, false
    result = system("rspec #{spec_dir} --format progress --no-color 2>&1")
    if result
      say "OK", :green
      passed += 1
    else
      say "FAIL", :red
      failed += 1
      errors << name
    end
  end

  # Also run appeal specs if they exist
  appeal_spec = File.join(Dir.pwd, "spec", "appeal")
  if File.directory?(appeal_spec)
    say "appeal... ", nil, false
    result = system("rspec #{appeal_spec} --format progress --no-color 2>&1")
    if result
      say "OK", :green
      passed += 1
    else
      say "FAIL", :red
      failed += 1
      errors << "appeal"
    end
  end

  say ""
  say "#{passed + failed} domains tested: #{passed} passed, #{failed} failed"
  if errors.any?
    say "Failed: #{errors.join(", ")}", :red
    exit 1
  end
end
