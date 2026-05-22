# i708 — agents coordinate through storehouse (the swarm's shared blackboard)

`SendMessage` between agents is not provisioned in this environment — but every
spawned agent CAN dispatch through the bus (proven tonight : a fully sandbox-
walled agent reached `Tools::ShellTool.Bash` via `mcp__storehouse__storehouse__dispatch`).
So **storehouse is the inter-agent channel.** Agents do not message each other
directly ; they communicate by reading and writing shared aggregate state.

## The mechanism : stigmergy through .heki

`aggregates/framework/sidequest/sidequest.bluebook` is the blackboard
(Propose / Volunteer / Claim / Complete / Fail ; Open / Mine queries) :
- one agent (or the macrophage) **Proposes** work — a dispatched command, durable in .heki ;
- a worker **queries Open**, **Claims** one, does it, **Completes** with the result ;
- the result is durable state, visible in `storehouse follow`.

This is stigmergy : coordination through traces left in a shared medium, the way
ants coordinate through pheromone. The bus is the medium ; the .heki state is the
trace. No orchestrator threads prompts between workers.

## Implications

1. The main session stops being the message router — the swarm self-organises.
2. Agents run truly independently, polling the blackboard on a loop.
3. Results are durable (.heki) and observable (`follow`), not trapped in a
   transcript.
4. Composes directly with the fibroblast (i707) : the macrophage **posts** a
   complaint ; a fibroblast **claims** it, repairs, **posts** the outcome.
5. Solves the coordination gap hit tonight (no SendMessage) without new plumbing.

## Build

Extend `sidequest.bluebook` with the claim/result pattern fibroblasts need
(atomic claim so two workers don't grab the same task ; a heartbeat so a dead
worker's claim expires). Workers loop on the Open query through the bus. The
immune system (i707) is the first real consumer.
