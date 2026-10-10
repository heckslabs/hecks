module Hecks
  module Runtime
    class Registry
      # The checks a loaded hecksagon owes: roles need an authorization provider, attachments need
      # their sibling hecksagon, a bounded chapter needs its ACL, and a chapter's declared
      # capabilities need what they name. Mixed into {Verification}.
      module HecksagonRules
        private

        # Checked once against the merged hecksagon so a domain split across multiple
        # hecksagon files sees every `attaches` declaration first. A role is real
        # access control only once an authorization provider exists to check it against
        # (ADR 0025); a provider is recognized by declaring authorization, not by name.
        def refuse_ungoverned_roles!(hecksagon)
          return if authorization_provider_for(hecksagon.domain)

          bluebook_ir = bluebook(hecksagon.domain)
          return unless bluebook_ir

          offender = commands_in(bluebook_ir).find { |command| !command.role.to_s.empty? }
          return unless offender

          raise WiringError,
                "#{offender.hecks_fqn} declares role #{offender.role.inspect}, but " \
                "#{hecksagon.domain}'s hecksagon never #{authorization_attachment_hint} — role is only " \
                "real access control once an authorization provider is attached to check it against; " \
                "without that it is silent decoration, the exact defect this refusal exists to catch"
        end

        # `driven_by` names a driving adapter; a name none answers to would silently admit nothing.
        def refuse_unknown_driving!(hecksagon)
          unknown = hecksagon.driving - Bluebook::Hecksagon::DRIVING_ADAPTERS
          return if unknown.empty?

          raise WiringError,
                "#{hecksagon.domain} is driven_by #{unknown.map(&:inspect).join(", ")}, which no driving " \
                "adapter answers to — the adapters are #{Bluebook::Hecksagon::DRIVING_ADAPTERS.join(", ")}"
        end

        # `attaches` loads a bounded context; the consumer must declare the sibling hecksagon
        # that is its ACL (Governance/Identity/Privacy already do). A vendored package only
        # loads its `.bluebook` files, so persistence, Governance and the `translates` ACL live
        # on that sibling too, or cross-context field mapping has nowhere to be written.
        def refuse_unwired_attachments!(hecksagon)
          hecksagon.attachments.each do |attachment|
            next if hecksagon(attachment.chapter_name)

            raise WiringError, unwired_attachment_message(hecksagon, attachment)
          end
        end

        def unwired_attachment_message(hecksagon, attachment)
          chapter_name = attachment.chapter_name
          what = attachment.vendor? ? "vendored bluebook #{attachment.name.inspect}" : chapter_name.inspect
          "#{hecksagon.domain} attaches #{what} " \
            "(bounded context #{chapter_name}) but never declared " \
            "Hecks.hecksagon #{chapter_name.inspect} — put that sibling " \
            "(and any `translates` ACL) in context_map.hecksagon; " \
            "same-name blocks merge, order-independent."
        end

        # An explicit `bounded` mark on a consumer chapter always needs an ACL. `attaches`
        # marks the attached chapter bounded and requires the sibling
        # hecksagon above; they don't require a `translates` on it unless the consumer also
        # wrote `bounded`.
        # rust/host Google sign-in reads ir.json's membership/identity keys, never a deploy-time
        # env var; Membership without Identity means provision cannot Register/Link an identity.
        def refuse_membership_without_identity!
          return unless @declared.bluebooks.values.any? { |chapter| chapter.provides?(Bluebook::Capabilities::MEMBERSHIP) }
          return if @declared.bluebooks.values.any? { |chapter| chapter.provides?(Bluebook::Capabilities::IDENTITY) }

          raise WiringError,
                "a chapter that provides \"membership\" is loaded, but none provides " \
                "\"identity\" — rust/host Google sign-in cannot register or link an " \
                "identity from the hecksagon/world. Attach Identity (`attaches " \
                "\"Identity\"` plus a sibling Hecks.hecksagon \"Identity\") so the " \
                "identity verbs are exported onto ir.json, not guessed at deploy."
        end

        # A hecksagon attaches after its chapter builds, so this is the first point a
        # declared `:port_operation` capability can be checked against it.
        def refuse_unresolved_port_operations!
          @declared.bluebooks.each_value do |chapter|
            chapter.provides.each { |row| refuse_unresolved_port_operation!(chapter, row) }
          end
        end

        def refuse_unresolved_port_operation!(chapter, row)
          return unless Bluebook::Capabilities::CONTRACTS.dig(row.capability, row.key.to_sym) == :port_operation
          return if port_operation_declared?(chapter, row.verb)

          raise WiringError,
                "#{chapter.name} provides #{row.capability.inspect} #{row.key}: #{row.verb.inspect}, " \
                "but its hecksagon declares no such port operation — declare it with " \
                "`#{chapter.name}::Aggregate.port \"Port\" do operation \"Operation\" ... end`."
        end

        def port_operation_declared?(chapter, verb)
          aggregate_name, port_name, operation_name = verb.split(".", 3)
          ports = chapter.aggregate(aggregate_name)&.ports || []
          ports.any? { |port| port.name == port_name && port.operations.any? { |op| op.hecks_name == operation_name } }
        end

        def refuse_bounded_without_acl!(hecksagon)
          return unless hecksagon.bounded?
          return if hecksagon.translates.any?

          raise WiringError,
                "#{hecksagon.domain} is marked bounded but never declared a " \
                "translates ACL — a bounded chapter wraps in its own module and " \
                "cross-context field mapping lives on the hecksagon, not in " \
                "rust/host and not as a field list on the bluebook. " \
                "Add `translates \"Name\" do on Foreign::Event; trigger Local::Command, " \
                "with: { ... } end` (any field) or drop `bounded`."
        end

        # Derived from whichever framework members actually declare `provides
        # "authorization"` — never a hardcoded name.
        def authorization_attachment_hint
          providers = Framework.providers_of(Bluebook::Capabilities::AUTHORIZATION)
          return "attaches a chapter that provides \"authorization\" (no framework member declares one)" if providers.empty?

          providers.map { |name| "attaches #{name.inspect}" }.join(" or ")
        end

        # Every command this domain declares, an aggregate's own and every entity nested
        # inside one — the same reach dispatch-time role checking needs.
        def commands_in(bluebook_ir)
          bluebook_ir.aggregates.flat_map { |aggregate| aggregate.commands + aggregate.entities.flat_map(&:commands) }
        end
      end
    end
  end
end
