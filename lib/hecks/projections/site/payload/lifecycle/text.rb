# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module Payload
        module Lifecycle
          # The first half of the TypeScript module every driven project shares, up to the plan.
          # `__ROLE__` and `__HECKS__` stand for the role and the host module's import path.
          HEAD = <<~TS
            // Driving one aggregate from a save: what every driven collection shares.
            //
            // An editor's save says what the document should look like and where it should
            // be (live, withdrawn, cancelled). The domain answers with where the aggregate
            // is now. This works out the commands between the two: create it if the domain
            // has never seen it, Revise when its facts differ, then walk its lifecycle to
            // the wanted status along the shortest path the bluebook allows.
            //
            // The pure parts (the plan) are separate from `drive`, the one function that
            // talks to the domain, so the decisions test without a network.
            import { domain, instancesOf, refusalOf, type Answer } from __HECKS__;

            /** The role every driven command declares; the host compares the role as a plain string. */
            const ROLE = __ROLE__;

            export type Wire = Record<string, unknown>;

            export interface Command<S> {
              verb: string;
              to?: string;
              with: Wire;
              /** True when the instances that came back show the command took effect. */
              confirm: (after: S[]) => boolean;
            }

            export interface Instance {
              slug: string;
              status: string;
            }

            export interface Spec<S extends Instance, I extends { slug: string }> {
              /** The aggregate as the host names it, chapter first: "Club::Event". */
              aggregate: string;
              /** Its instances in an answer, keyed by slug. */
              read: (answer: Answer) => S[];
              /** What the host holds, in the shape a save produces, so the two compare. */
              toInput: (state: S) => Omit<I, "status">;
              /** Every attribute but the slug, as `Revise` takes it. */
              fields: (input: Omit<I, "status">) => Wire;
              /** The command that creates one (it takes the slug and the fields) and the status it leaves it in. */
              create: { verb: string; status: string };
              /** The lifecycle: from a status, the commands that leave it and where they lead. */
              edges: Record<string, Record<string, string>>;
            }

            /** A refusal-free plan: nothing is sent for a status the domain cannot reach from where it is. */
            export class UnreachableStatus extends Error {}

            export const wrapped = (value: string) => ({ value });
            export const optionalValue = (name: string, value: string | null | undefined) => (value ? { [name]: wrapped(value) } : {});

            /** The text inside a one-attribute value object (`{value}`, `{url}`, `{address}`), or null. */
            export function unwrap(value: unknown): string | null {
              if (typeof value === "string") return value || null;
              if (value && typeof value === "object") {
                for (const key of ["value", "url", "address"]) {
                  const inner = (value as Record<string, unknown>)[key];
                  if (typeof inner === "string" && inner) return inner;
                }
              }
              return null;
            }

            export const unwrapList = (value: unknown): string[] =>
              Array.isArray(value) ? value.map(unwrap).filter((item): item is string => !!item) : [];

            export const statusOf = (state: Record<string, unknown>): string => (typeof state.status === "string" ? state.status : "");

          TS
        end
      end
    end
  end
end
