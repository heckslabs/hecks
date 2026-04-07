Hecks::Chapters.load_aggregates(
  Hecks::Chapters::Cli::CliInternals,
  base_dir: File.expand_path("..", __dir__)
)

Hecks::CLI.register_command(:new_project, "Create a new Hecks project",
  args: ["NAME"],
  options: {
    "no-world-goals": { type: :boolean, desc: "Skip world concerns prompt (for CI)", default: false }
  }
) do |name|
  pascal = Hecks::Utils.sanitize_constant(name)
  dir = name

  if File.exist?(dir)
    say "Directory #{dir} already exists", :red
    next
  end

  world_result = if options[:"no-world-goals"]
    { concerns: [], extensions: [], stub: false }
  else
    Hecks::WorldConcernsPrompt.new(say_method: method(:say)).run
  end

  app_template = lambda do
    <<~RUBY
      require "hecks"

      app = Hecks.boot(__dir__)
    RUBY
  end

  hecksagon_template = lambda do
    <<~HEC
      Hecks.hecksagon "#{pascal}" do
        capabilities :crud
      end
    HEC
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
      app.capability(:crud)

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

  write_or_diff(
    File.join(dir, "bluebook.hec"),
    domain_template(pascal,
      world_concerns: world_result[:concerns],
      extensions:     world_result[:extensions],
      stub:           world_result[:stub])
  )
  write_or_diff(File.join(dir, "hecksagon.hec"), hecksagon_template.call)
  write_or_diff(File.join(dir, "#{name}.rb"), app_template.call)
  write_or_diff(File.join(dir, "Gemfile"), gemfile_template.call)
  write_or_diff(File.join(dir, "spec", "spec_helper.rb"), spec_helper_template.call)
  write_or_diff(File.join(dir, ".gitignore"), gitignore_template.call)
  write_or_diff(File.join(dir, ".rspec"), rspec_template.call)

  if world_result[:concerns].any? || world_result[:stub]
    say ""
    say "Domain created. World concerns declared.", :green
  else
    say "Created #{dir}/", :green
  end
  say "  bluebook.hec"
  say "  hecksagon.hec"
  say "  #{name}.rb"
  say "  Gemfile"
  say "  spec/spec_helper.rb"
  say "  .gitignore"
  say "  .rspec"
  say ""
  say "Get started:"
  say "  cd #{dir}"
  say "  bundle install"
  say "  ruby #{name}.rb"
end
