# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module Payload
        module Lifecycle
          # The second half of the TypeScript module: the plan, and the function that drives it.
          TAIL = <<~TS
            /** The verbs, in order, that take an aggregate from one status to another; null when none does. */
            export function pathBetween(edges: Record<string, Record<string, string>>, from: string, to: string): string[] | null {
              if (from === to) return [];
              const seen = new Set([from]);
              let frontier: { status: string; verbs: string[] }[] = [{ status: from, verbs: [] }];
              while (frontier.length) {
                const next: typeof frontier = [];
                for (const { status, verbs } of frontier) {
                  for (const [verb, target] of Object.entries(edges[status] ?? {})) {
                    if (seen.has(target)) continue;
                    if (target === to) return [...verbs, verb];
                    seen.add(target);
                    next.push({ status: target, verbs: [...verbs, verb] });
                  }
                }
                frontier = next;
              }
              return null;
            }

            const stateOf = <S extends Instance>(after: S[], slug: string) => after.find((s) => s.slug === slug);

            /**
             * The commands that make the domain's aggregate match `input` and sit in
             * `desired`. `desired` null means "not on the site": a document the domain has
             * never seen sends nothing; one it holds is walked to `withdrawn`.
             */
            export function planCommands<S extends Instance, I extends { slug: string }>(
              spec: Spec<S, I>,
              current: S | undefined,
              input: Omit<I, "status">,
              desired: string,
            ): Command<S>[] {
              const slug = input.slug;
              const fields = spec.fields(input);
              const commands: Command<S>[] = [];
              let status = current?.status;

              if (!current) {
                if (spec.create.status !== desired && !pathBetween(spec.edges, spec.create.status, desired)) {
                  throw new UnreachableStatus(`${spec.aggregate} cannot reach "${desired}" from "${spec.create.status}".`);
                }
                commands.push({
                  verb: spec.create.verb,
                  with: { slug: wrapped(slug), ...fields },
                  confirm: (after) => stateOf(after, slug)?.status === spec.create.status,
                });
                status = spec.create.status;
              } else if (JSON.stringify(spec.fields(spec.toInput(current))) !== JSON.stringify(fields)) {
                commands.push({
                  verb: "Revise",
                  to: slug,
                  with: fields,
                  confirm: (after) => {
                    const now = stateOf(after, slug);
                    return !!now && JSON.stringify(spec.fields(spec.toInput(now))) === JSON.stringify(fields);
                  },
                });
              }

              const path = pathBetween(spec.edges, status ?? "", desired);
              if (path === null) throw new UnreachableStatus(`${spec.aggregate} "${slug}" cannot go from "${status}" to "${desired}".`);
              let at = status ?? "";
              for (const verb of path) {
                const to = spec.edges[at][verb];
                commands.push({ verb, to: slug, with: {}, confirm: (after) => stateOf(after, slug)?.status === to });
                at = to;
              }
              return commands;
            }

            /** Runs the plan against the domain; a command whose result does not show it took effect throws the domain's own words. */
            export async function drive<S extends Instance, I extends { slug: string }>(
              spec: Spec<S, I>,
              input: Omit<I, "status">,
              desired: string | null,
              /** The status that means "off the site", used when `desired` is null and the domain holds the aggregate. */
              offSite: string,
            ): Promise<void> {
              const current = spec.read(await domain().read()).find((s) => s.slug === input.slug);
              // Not on the site and never was (a draft): the domain hears nothing about it.
              if (desired === null && !current) return;
              for (const command of planCommands(spec, current, input, desired ?? offSite)) {
                const verb = `${spec.aggregate.split("::")[1]}.${command.verb}`;
                const answer = await domain().dispatch(verb, command.with, command.to, ROLE);
                if (!command.confirm(spec.read(answer))) throw refusalOf(answer, verb);
              }
            }

            /** Reads an aggregate's instances, slug first, from an answer. */
            export const instancesBySlug = (answer: Answer, aggregate: string) => instancesOf(answer, aggregate);
          TS
        end
      end
    end
  end
end
