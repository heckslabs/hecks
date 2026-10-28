# A box is reached through its edge, and no third-party tunnel runs on it

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-28. Supersedes the `tunnel` setting of [ADR 0085](0085-aws-box-is-a-deploy-kind-one-ec2-box-and-one-rds-instance.md) (items 5 and 6, and the tunnel half of item 7).

## Context

ADR 0085 gave the `AwsBox` kind a `tunnel` setting. `tunnel true` opened outbound port 7844 for a tunnel the project ran itself. `tunnel({ to:, token_secret: })` also ran a `cloudflared` container beside the project's containers, let the box role read the tunnel's token, and held the roll until a connection registered.

That put a third party's account, DNS zone and credentials in the path to a box that otherwise has one public entrance: a CDN or load balancer in front of Caddy, which refuses every request without the origin secret (ADR 0108). A tunnel is a second entrance with its own authentication, rate limits and outage, none of which the box stack can see or alarm on. The account credentials that set one up also have to live somewhere other than the secret store the rest of the box uses.

Reading every project this repository knows, none declares `tunnel` in its world. What exists is the dormant branch of the generated `render-compose.sh`, which renders a `cloudflared` service only when a tunnel is declared, and a hand-written script in one client that runs a tunnel beside an analytics container. The generator was offering a path nobody takes through it, and the hand-written use is outside what it generates.

## Decision

A box is reached through the CDN or load balancer and Caddy, with an origin-secret header. No third-party tunnel runs on it.

1. The `tunnel` setting is removed, in both forms. The generator no longer writes the `cloudflared` service, the outbound 7844 rule, the tunnel's token secret in the role policy, the registered-connection check after a roll, the `tunnel` entry in `services.json`, or the pinned `cloudflared` image.
2. A world that still declares `tunnel` is refused when the box is planned, with a message that names this ADR and says to declare `cdn` and `origin_secret` instead. It is refused, not ignored, so a box does not lose a tunnel it relied on without anyone being told.
3. A container that used to sit behind a tunnel is reached the way every other container is: a `routes` entry sends a path to it through Caddy, and `cdn` aliases give the edge the host names. A container that must not be public stays on the box's private network and is reached over an SSM port-forward, which needs no inbound rule.
4. The generated `render-compose.sh` loses its tunnel branch the next time a project regenerates, which changes nothing for a project that declared none.

## What this does not decide

- Moving a DNS zone off a third party, or replacing the analytics a project ran behind a tunnel. Those are per-project changes with their own rehearsal.
- Hand-written scripts in a project that run a tunnel outside the generated stack. They keep working until the project moves them; the generator no longer helps and no longer vouches for them.
- [ADR 0090](0090-deploy-scripts-become-commands-on-the-deploy-chapter.md) lists a companion roll that might one day be projected from a declared companion's image, secrets and tunnel. With this ADR a companion declares no tunnel; the rest of that note stands.

## Consequences

- **Removed:** the `tunnel` golden world, the `tunnel-egress.yaml` template, the tunnel probe, the `TUNNEL_IMAGE` and `TUNNEL_SHAPE` constants, and the specs that pinned them. The other goldens change in their `render-compose.sh` only, and the full world's `box.yaml` loses the 7844 rule.
- **Added:** a refusal for a world that declares `tunnel`, with a spec.
- A project that declared a tunnel and bumps to this version is told so at the plan, before anything is rolled.
