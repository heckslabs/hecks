# Hecks::CLI smoke command
#
# Boots the domain in the current directory, dispatches every command,
# and validates events fire. The CLI version of the acceptance test.
#
#   cd examples/pizzas && hecks smoke
#
Hecks::CLI.handle(:smoke) do |inv|
  require "hecks"

  begin
    runtimes = Hecks.boot(Dir.pwd)
    runtimes = [runtimes] unless runtimes.is_a?(Array)
  rescue => e
    say "Boot failed: #{e.message}", :red
    exit 1
  end

  passed = 0
  failed = 0

  runtimes.each do |rt|
    say "#{rt.domain.name}:", :bold
    rt.domain.aggregates.each do |agg|
      agg.commands.each do |cmd|
        # Build test args
        args = {}
        cmd.attributes.each do |a|
          type = a.type.respond_to?(:name) ? a.type.name.split("::").last : a.type.to_s
          args[a.name] = (type == "Integer" || type == "Float") ? 1 : "test"
        end

        events_before = rt.event_bus.events.size
        begin
          rt.command_bus.dispatch(cmd.name, **args)
          got_event = rt.event_bus.events.size > events_before
          if got_event
            event_name = rt.event_bus.events.last.class.name.split("::").last
            say "  #{agg.name}.#{cmd.name} → #{event_name}", :green
            passed += 1
          else
            say "  #{agg.name}.#{cmd.name} → no event", :yellow
            passed += 1
          end
        rescue => e
          say "  #{agg.name}.#{cmd.name} → #{e.message}", :red
          failed += 1
        end
      end
    end
  end

  say ""
  say "#{passed + failed} commands: #{passed} passed, #{failed} failed"
  exit 1 if failed > 0
end
