Hecks::CLI.register_command(:new_project, "Create a new Hecks project",
  args: ["NAME"]
) do |name|
  pascal = Hecks::Utils.sanitize_constant(name)
  dir = name

  if File.exist?(dir)
    say "Directory #{dir} already exists", :red
    next
  end

  available_goals = %i[transparency consent privacy security]
  selected_goals = []

  if $stdin.tty?
    say ""
    say "World goals are opt-in ethical validation rules for your domain.", :cyan
    say "Available: #{available_goals.map { |g| ":#{g}" }.join(", ")}"
    say "Enter goals (space-separated), or press Enter to skip:"
    input = $stdin.gets&.chomp
    if input && !input.strip.empty?
      selected_goals = input.strip.split(/\s+/).map(&:to_sym) & available_goals
    end
  end

  app_template = lambda do
    <<~RUBY
      require "hecks"

      app = Hecks.boot(__dir__)

      # Start building:
      #   Example.create(name: "Hello")
      #   Example.all
    RUBY
  end

  gemfile_template = lambda do
    hecks_spec = ::Gem.loaded_specs["hecks"]
    if hecks_spec && hecks_spec.full_gem_path != File.expand_path("../../../..", __FILE__)
      gem_line = 'gem "hecks"'
    else
      hecks_root = File.expand_path("../../../..", __FILE__)
      gem_line = "gem \"hecks\", path: \"#{hecks_root}\""
    end

    <<~RUBY
      source "https://rubygems.org"
      #{gem_line}
    RUBY
  end

  spec_helper_template = lambda do
    <<~RUBY
      require "hecks"
      app = Hecks.boot(File.join(__dir__, ".."))

      RSpec.configure do |config|
        config.order = :random
      end
    RUBY
  end

  gitignore_template = lambda do
    <<~TEXT
      *.gem
      *_domain/
    TEXT
  end

  rspec_template = lambda do
    <<~TEXT
      --format documentation
      --color
      --require spec_helper
    TEXT
  end

  FileUtils.mkdir_p(File.join(dir, "spec"))

  write_or_diff(File.join(dir, "#{pascal}Bluebook"), domain_template(pascal, world_goals: selected_goals))
  write_or_diff(File.join(dir, "app.rb"), app_template.call)
  write_or_diff(File.join(dir, "Gemfile"), gemfile_template.call)
  write_or_diff(File.join(dir, "spec", "spec_helper.rb"), spec_helper_template.call)
  write_or_diff(File.join(dir, ".gitignore"), gitignore_template.call)
  write_or_diff(File.join(dir, ".rspec"), rspec_template.call)

  say "Created #{dir}/", :green
  say "  #{pascal}Bluebook"
  say "  app.rb"
  say "  Gemfile"
  say "  spec/spec_helper.rb"
  say "  .gitignore"
  say "  .rspec"
  say ""
  say "Get started:"
  say "  cd #{dir}"
  say "  bundle install"
  say "  ruby app.rb"
end
