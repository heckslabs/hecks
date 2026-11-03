# deliver

Take finished work into the shared line. Use it to commit a change, land a branch on local
main, and send main onward.

**Concept.** A checkout is one working copy of the repository. A landing merges a worktree's
branch onto local main, never forced and never pushed. A push train sends local main in turn,
behind whatever was pushed before it.

**Example: see where your work stands**

```sh
hecks Workspace.status
```

Prints the checkout's branch, whether it is a linked worktree, and where it stands against main.

**Example: land a branch on local main**

```sh
hecks Landing.land! --confirm checkout.value=/path/to/worktree branch.value=my-branch
```

Fast-forwards main when it can, and makes a merge commit when main has moved.

**Example: run the gate, land and send finished work**

```sh
hecks Shipment.ship! branch.value=my-branch
```

Starts the gate-and-board saga for the branch.

Run `hecks deliver` for every command in this module, grouped by aggregate.
