require "json"
require_relative "../command_form_renderer"
require_relative "../params"
require_relative "../../adapters/driving/command_request"
require_relative "../../adapters/driving/json"

module Hecks
  module Forms
    class App
      # The command routes of `Forms::App`: the form, its submission, and the JSON adapter to the
      # same
      # dispatch.
      module Commands
        private

        def command_route(request, domain, aggregate, command, format)
          action = "/#{domain}/#{aggregate.hecks_name}/#{command.hecks_name}.html"
          return command_json(request, domain, aggregate, command) if format != "html"
          if request.get?
            return command_form(domain, aggregate, command, action,
                                prefill: receiver_compatibility(request.GET, command))
          end
          return respond(405, "text/plain", "GET or POST only") unless request.post?

          submit_command(request, domain, aggregate, command, action)
        end

        # @param page [Hash] optionally `status:`, the submitted `values:`, the `error:` to show and
        #   the `prefill:` values
        def command_form(domain, aggregate, command, action, **page)
          html("#{domain}::#{aggregate.hecks_name}.#{command.hecks_name}",
               CommandFormRenderer.render(registry: @registry, domain: domain, aggregate: aggregate, command: command,
                                          action: action, **page.slice(:values, :error, :prefill)),
               breadcrumbs: [[domain, "/"], [aggregate.hecks_name, "/#{domain}/#{aggregate.hecks_name}.html"],
                             [command.hecks_name, nil]],
               status:      page.fetch(:status, 200))
        end

        def submit_command(request, domain, aggregate, command, action)
          raw, envelope = submitted_command(request, aggregate, command)
          result = @dispatcher.dispatch_flat(verb_name(domain, aggregate, command), envelope)
          # The id is free-form, so it is percent-encoded as a path segment.
          redirect("/#{domain}/#{aggregate.hecks_name}/#{Escape.path(result.id)}.html")
        rescue *Runtime::DOMAIN_REFUSALS, ArgumentError, TypeError, JSON::ParserError => e
          command_form(domain, aggregate, command, action, status: refusal_status(e), values: raw, error: e)
        end

        def command_json(request, domain, aggregate, command)
          return json(200, command.to_h) if request.get? && request.GET.except("format").empty?
          return respond(405, "text/plain", "GET or POST only") unless request.post?

          created_json(request, domain, aggregate, command)
        rescue *Runtime::DOMAIN_REFUSALS, ArgumentError, TypeError, JSON::ParserError => e
          refusal_json(e, refusal_status(e))
        end

        def created_json(request, domain, aggregate, command)
          _, envelope = submitted_command(request, aggregate, command)
          result = @dispatcher.dispatch_flat(verb_name(domain, aggregate, command), envelope)
          # `id:` last, as in `aggregate_route`.
          json(201, result.state.merge(id: result.id))
        end

        def verb_name(domain, aggregate, verb) = "#{domain}::#{aggregate.hecks_name}.#{verb.hecks_name}"

        def command_envelope(command, args)
          Adapters::Driving::CommandRequest.normalize(args, receiver: command_receiver(command), legacy_receiver: :id)
        end

        def command_receiver(command) = command.creates? ? nil : :aggregate

        def submitted_command(request, aggregate, command)
          return submitted_json(request, command) if request.media_type == "application/json"

          raw = receiver_compatibility(request.POST, command)
          fields = CommandFormRenderer.fields_for(aggregate, command)
          args = Params.extract(fields, raw)
          [raw, command_envelope(command, args)]
        end

        def submitted_json(request, command)
          raw = Adapters::Driving::Json.parse(request.body.read)
          envelope = Adapters::Driving::Json.command_request(raw, receiver:        command_receiver(command),
                                                                  legacy_receiver: :id)
          [raw, envelope]
        end

        # Existing integrations may still submit id. It remains an accepted
        # edge spelling, but new forms expose only the receiver name to.
        def receiver_compatibility(raw, command)
          return raw if command.creates?
          return raw unless raw.key?("id") && !raw.key?("to")

          raw.merge("to" => raw["id"])
        end
      end
    end
  end
end
