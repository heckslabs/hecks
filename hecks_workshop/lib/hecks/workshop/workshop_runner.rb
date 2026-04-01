require_relative "workshop_runner/constant_hoister"

module Hecks
  class Workshop
    # Hecks::Workshop::WorkshopRunner
    #
    # Interactive IRB workshop for domain modeling. Delegates workshop
    # methods and hoists constants so users can type `Pizza.title String`
    # directly in the REPL.
    #
    #   WorkshopRunner.new(name: "Pizzas").run
    #
    class WorkshopRunner
      include HecksTemplating::NamingHelpers
      include ConstantHoister

    def initialize(name: nil)
      @name = name
    end

    # Delegate workshop methods for direct REPL access
    %i[
      aggregates remove add_verb active_hecks!
      validate preview describe build save to_dsl status browse
      play! sketch! serve! events events_of commands history reset!
      promote visualize
    ].each do |m|
      define_method(m) do |*args, **kwargs, &block|
        @workshop.send(m, *args, **kwargs, &block)
      end
    end

    def list_of(type) = { list: type }

    def aggregate(name, &block)
      is_new = !@workshop.aggregate_builders.key?(domain_constant_name(name))
      handle = @workshop.aggregate(name, &block)
      hoist_aggregate(domain_constant_name(name).to_sym, handle)
      puts "#{domain_constant_name(name)} aggregate created" if is_new && !block
      handle
    end

    def extend(name, **kwargs)
      @workshop.extend(name, **kwargs)
    end

    def play!
      result = @workshop.play!
      if @workshop.play? && @workshop.playground
        mod_name = domain_module_name(@workshop.name)
        if Object.const_defined?(mod_name)
          hoist_domain_constants(Object.const_get(mod_name))
        end
      end
      result
    end

    def sketch!
      # Unload the domain module (removes hoisted constants + module itself)
      mod_name = domain_module_name(@workshop.name)
      if Object.const_defined?(mod_name)
        mod = Object.const_get(mod_name)
        mod.unload! if mod.respond_to?(:unload!)
      end
      unhoist_all
      @workshop.sketch!
    end

    def backtrace!
      @show_backtrace = true
      puts "Backtrace on"
      nil
    end

    def quiet!
      @show_backtrace = false
      puts "Backtrace off"
      nil
    end

    def help
      print_help
      nil
    end

    def inspect
      mode = @workshop&.play? ? "play" : "sketch"
      name = @workshop&.name&.downcase || "scratch"
      event = last_event_label
      event ? "hecks(#{name} #{mode}) [#{event}]" : "hecks(#{name} #{mode})"
    end

    def to_s = inspect

    def last_event
      return nil unless @workshop&.play? && @workshop&.playground
      @workshop.playground.events.last
    end

    def tour
      @workshop = Hecks.workshop("Tour")
      Tour.new(self).start
    end

    def run
      require "irb"
      @workshop = setup_session
      print_help
      launch_irb
    end

    # Public so WebRunner can reuse session setup without launching IRB
    def setup_workshop
      setup_session
    end

    # Returns a binding in WorkshopRunner's method context so constant
    # lookup resolves hoisted constants on this class.
    def eval_binding
      binding
    end

    private

    def last_event_label
      return nil unless @workshop&.play? && @workshop&.playground
      event = @workshop.playground.events.last
      return nil unless event
      Hecks::Utils.const_short_name(event)
    end

    def launch_irb
      history_file = File.join(Dir.home, ".hecks_history")
      IRB.setup(nil)
      IRB.conf[:HISTORY_FILE] = history_file
      IRB.conf[:SAVE_HISTORY] = 1000
      load_history(history_file)

      workspace = IRB::WorkSpace.new(binding)
      irb = IRB::Irb.new(workspace)
      IRB.conf[:MAIN_CONTEXT] = irb.context

      @show_backtrace = false
      install_exception_handler(irb)
      catch(:IRB_EXIT) { irb.eval_input }
      save_history(history_file)
    end

    def load_history(path)
      return unless defined?(Reline) && File.exist?(path)
      File.readlines(path, chomp: true).each { |line| Reline::HISTORY << line } rescue nil
    end

    def save_history(path)
      return unless defined?(Reline)
      File.open(path, "w") { |f| Reline::HISTORY.last(1000).each { |line| f.puts(line) } }
    end

    def install_exception_handler(irb)
      runner = self
      irb.define_singleton_method(:handle_exception) do |exc|
        if runner.instance_variable_get(:@show_backtrace)
          super(exc)
        else
          puts "#{exc.class}: #{exc.message}"
        end
      end
    end

    def setup_session
      if @name
        workshop = Hecks.workshop(@name)
        puts "Started workshop: #{@name}"
        return workshop
      end

      if File.exist?("Bluebook")
        Dir["*Bluebook"].each { |f| Kernel.load(f) }
        domain = Hecks.last_domain
        workshop = Hecks.workshop(domain.name)
        domain.aggregates.each do |agg|
          workshop.aggregate_builders[agg.name] =
            DSL::AggregateRebuilder.from_aggregate(agg)
        end
        puts "Loaded domain from domain.rb: #{domain.name}"
        return workshop
      end

      workshop = Hecks.workshop("MyDomain")
      puts "Started new workshop: MyDomain"
      workshop
    end

    def print_help
      puts ""
      puts "  Post                             # create aggregate"
      puts "  Post.title String                # add attribute"
      puts "  Post.create                      # add command"
      puts "  Post.create.title String         # add attribute to command"
      puts "  Post.lifecycle :status, default: \"draft\""
      puts "  Post.transition \"PublishPost\" => \"published\""
      puts ""
      puts "  play! / sketch!                  # switch modes"
      puts "  save / build"
      puts "  validate / describe / preview / browse"
      puts "  visualize                        # print Mermaid diagrams"
      puts "  visualize(:browser)              # open in browser"
      puts "  visualize(:file, type: :flows)   # write .md file"
      puts ""
    end
  end
  end
end
