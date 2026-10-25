require "json"
require_relative "../command_form_renderer"
require_relative "../params"
require_relative "../../adapters/driving/command_request"
require_relative "../../adapters/driving/json"
require_relative "../../projections/command_schema"

module Hecks
  module Forms
    class App
      # The command routes of `Forms::App`: the form, its submission, and the JSON adapter to the
      # same
      # dispatch.
      module Commands
        # The values of `dry_run=` / `X-Dry-Run:` that ask for a validation instead of a dispatch.
        DRY_RUN_FLAGS = %w[1 true].freeze

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
          html(Humanize.phrase(command.hecks_name),
               CommandFormRenderer.render(registry: @registry, domain: domain, aggregate: aggregate, command: command,
                                          action: action, **page.slice(:values, :error, :prefill)),
               breadcrumbs: verb_breadcrumbs(domain, aggregate, command),
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
          return command_read_json(request, domain, aggregate, command) if request.get?
          return respond(405, "text/plain", "GET or POST only") unless request.post?
          return validated_json(request, domain, aggregate, command) if dry_run_requested?(request)

          created_json(request, domain, aggregate, command)
        rescue *Runtime::DOMAIN_REFUSALS, ArgumentError, TypeError, JSON::ParserError => e
          refusal_json(e, refusal_status(e))
        end

        # A GET of a command's JSON route: its descriptor, or with `?schema=1` its JSON Schema.
        def command_read_json(request, domain, aggregate, command)
          return command_schema(domain, aggregate, command) if request.GET["schema"] == "1"
          return json(200, command.to_h) if request.GET.except("format").empty?

          respond(405, "text/plain", "GET or POST only")
        end

        # The JSON Schema of the facts the command takes (`?schema=1`), with the rules a schema
        # cannot hold as `x-` annotations.
        def command_schema(domain, aggregate, command)
          path = "#{aggregate.hecks_name}/#{command.hecks_name}"
          json(200, Projections::CommandSchema.document(@registry.bluebook(domain), aggregate, path, command))
        end

        # Whether the request asks to be validated, not carried out: `?dry_run=1` or `X-Dry-Run: 1`.
        def dry_run_requested?(request)
          DRY_RUN_FLAGS.include?(request.GET["dry_run"].to_s) || DRY_RUN_FLAGS.include?(request.get_header("HTTP_X_DRY_RUN").to_s)
        end

        # The same body, caller and route as the real command, answered as every reason it would be
        # refused. A completed validation is a 200 whether or not it refused.
        def validated_json(request, domain, aggregate, command)
          _, envelope = submitted_command(request, aggregate, command)
          json(200, @dispatcher.validate(verb_name(domain, aggregate, command), envelope).to_h)
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
          body = request.body
          raw = Adapters::Driving::Json.parse(body.read)
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
