# Hecks::CLI smoketest command
#
# Context-aware: runs in the current directory.
# In a project dir (has hecks/ but no examples/): runs that project's specs.
# In the hecks root (has examples/): runs all example + framework specs.
#
#   cd examples/pizzas && hecks smoketest   # tests pizzas
#   cd /path/to/hecks && hecks smoketest    # tests all examples + appeal
#
Hecks::CLI.register_command(:smoketest, "Run smoke tests for this app or all examples") do
  examples_dir = File.join(Dir.pwd, "examples")
  spec_dir = File.join(Dir.pwd, "spec")

  if File.directory?(examples_dir)
    # At the hecks root — run everything
    passed = 0
    failed = 0
    errors = []

    # Example domain specs
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

    # Framework specs (appeal, etc.)
    Dir[File.join(spec_dir, "*/")].sort.each do |sd|
      next unless Dir[File.join(sd, "*_spec.rb")].any?
      name = File.basename(sd)
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

    say ""
    say "#{passed + failed} suites: #{passed} passed, #{failed} failed"
    if errors.any?
      say "Failed: #{errors.join(", ")}", :red
      exit 1
    end

  elsif File.directory?(File.join(Dir.pwd, "spec"))
    # In a project — run its specs
    say "Running specs in #{Dir.pwd}...", :bold
    success = system("rspec #{spec_dir} --format documentation")
    exit(success ? 0 : 1)

  else
    say "No spec/ or examples/ directory found", :red
    exit 1
  end
end
