Hecks::CLI.handle(:generate_sinatra) do |inv|

  domain = resolve_domain_option
  next unless domain

  sinatra_gemfile = lambda do |d|
    <<~RUBY
      source "https://rubygems.org"

      gem "sinatra"
      gem "sinatra-contrib"
      gem "hecks"
      gem "#{d.gem_name}", path: "../#{d.gem_name}"
    RUBY
  end

  sinatra_config_ru = lambda do
    <<~RUBY
      require_relative "app"
      run App
    RUBY
  end

  sinatra_app_rb = lambda do |d|
    mod = domain_module_name(d.name)
    routes = []

    d.aggregates.each do |agg|
      slug = domain_aggregate_slug(agg.name)
      klass = "#{agg.name}"

      agg.queries.each do |query|
        qn = domain_snake_name(query.name)
        params = query.block.parameters
        if params.empty?
          routes << "  get '/#{slug}/#{qn}' do\n    json #{klass}.#{qn}.map { |r| serialize(r) }\n  end"
        else
          args = params.map { |_, n| "params[:#{n}]" }.join(", ")
          routes << "  get '/#{slug}/#{qn}' do\n    json #{klass}.#{qn}(#{args}).map { |r| serialize(r) }\n  end"
        end
      end

      routes << "  get '/#{slug}' do\n    json #{klass}.all.map { |r| serialize(r) }\n  end"
      routes << "  get '/#{slug}/:id' do\n    result = #{klass}.find(params[:id])\n    halt 404, json(error: 'Not found') unless result\n    json serialize(result)\n  end"

      create_cmd = agg.commands.find { |c| c.name.start_with?("Create") }
      if create_cmd
        method_name = domain_command_method(create_cmd.name, agg.name)
        routes << "  post '/#{slug}' do\n    attrs = JSON.parse(request.body.read, symbolize_names: true)\n    result = #{klass}.#{method_name}(**attrs)\n    status 201\n    json serialize(result)\n  end"
      end

      routes << "  delete '/#{slug}/:id' do\n    #{klass}.delete(params[:id])\n    json deleted: params[:id]\n  end"
    end

    <<~RUBY
      require "sinatra"
      require "sinatra/json"
      require_relative "config/hecks"

      class App < Sinatra::Base
        helpers Sinatra::JSON

        before do
          content_type :json
          headers "Access-Control-Allow-Origin" => "*",
                  "Access-Control-Allow-Methods" => "GET, POST, PATCH, DELETE, OPTIONS",
                  "Access-Control-Allow-Headers" => "Content-Type"
        end

        options "*" do
          200
        end

      #{routes.join("\n\n")}

        private

        def serialize(obj)
          Hecks::Utils.object_attr_names(obj).each_with_object({}) do |name, h|
            next unless obj.respond_to?(name)
            val = obj.send(name)
            h[name] = val.is_a?(Time) ? val.iso8601 : val
          end
        end
      end
    RUBY
  end

  sinatra_hecks_config = lambda do |d|
    <<~RUBY
      require "hecks"
      require "#{d.gem_name}"

      # Load the domain
      domain_file = Dir[File.join(Gem.loaded_specs["#{d.gem_name}"]&.full_gem_path || "../#{d.gem_name}", "*Bluebook")].first
      DOMAIN = eval(File.read(domain_file), TOPLEVEL_BINDING, domain_file)

      # Boot with memory adapters (swap to SQL for production)
      APP = Hecks.load(DOMAIN)

      # Uncomment for SQL persistence:
      # Hecks.configure do
      #   domain "#{d.gem_name}"
      #   adapter :sql, database: :sqlite, name: "#{domain_snake_name(d.module_name)}.db"
      #   include_ad_hoc_queries
      # end
    RUBY
  end

  app_name = options[:dir] || "#{domain_snake_name(domain.module_name)}_app"

  FileUtils.mkdir_p(app_name)
  FileUtils.mkdir_p(File.join(app_name, "config"))

  write_or_diff(File.join(app_name, "Gemfile"), sinatra_gemfile.call(domain))
  write_or_diff(File.join(app_name, "config.ru"), sinatra_config_ru.call)
  write_or_diff(File.join(app_name, "app.rb"), sinatra_app_rb.call(domain))
  write_or_diff(File.join(app_name, "config/hecks.rb"), sinatra_hecks_config.call(domain))

  say "Generated Sinatra app: #{app_name}/", :green
  say "  Gemfile      — dependencies"
  say "  config.ru    — rackup entry point"
  say "  app.rb       — routes (edit this!)"
  say "  config/hecks.rb — domain configuration"
  say ""
  say "Next steps:"
  say "  cd #{app_name}"
  say "  bundle install"
  say "  ruby app.rb"
end
