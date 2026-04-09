# Hecks::CLI smoketest command
#
# Context-aware: runs in the current directory.
# In a project dir (has hecks/): runs that project's specs.
# In the hecks root (has examples/): runs all example specs.
#
#   cd examples/pizzas && hecks smoketest   # tests pizzas
#   cd /path/to/hecks && hecks smoketest    # tests all examples
#
Hecks::CLI.register_command(:smoketest, "Run smoke tests for this app or all examples") do
  spec_dir = File.join(Dir.pwd, "spec")
  examples_dir = File.join(Dir.pwd, "examples")

  if File.directory?(spec_dir)
    # In a project — run its specs
    say "Running specs in #{Dir.pwd}...", :bold
    success = system("rspec #{spec_dir} --format documentation")
    exit(success ? 0 : 1)

  elsif File.directory?(examples_dir)
    # At the hecks root — run all example specs
    passed = 0
    failed = 0
    errors = []

    # Example specs
    Dir[File.join(examples_dir, "*/spec")].sort.each do |sd|
      name = File.basename(File.dirname(sd))
      say "#{name}... ", nil, false
      if system("rspec #{sd} --format progress --no-color > /dev/null 2>&1")
        say "OK", :green
        passed += 1
      else
        say "FAIL", :red
        failed += 1
        errors << name
      end
    end

    # Appeal specs
    appeal_spec = File.join(Dir.pwd, "spec", "appeal")
    if File.directory?(appeal_spec)
      say "appeal... ", nil, false
      if system("rspec #{appeal_spec} --format progress --no-color > /dev/null 2>&1")
        say "OK", :green
        passed += 1
      else
        say "FAIL", :red
        failed += 1
        errors << "appeal"
      end
    end

    say ""
    say "#{passed + failed} domains: #{passed} passed, #{failed} failed"
    if errors.any?
      say "Failed: #{errors.join(", ")}", :red
      exit 1
    end

  else
    say "No spec/ or examples/ directory found", :red
    exit 1
  end
end
