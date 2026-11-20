# release

<!-- prose anchor="Concept" purpose="concept" supports="doc:docs/decisions/0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md code_file:lib/hecks/hecks/release/release.bluebook" -->
Certify, publish and pin versions. Use it to promote a lane to a commit that has passed every
check, publish the gem, and pin a registry package.

**Concept.** A lane is a branch that a release follows, such as `stable`. Promoting moves the
lane onto a commit that every required check has passed; with no `confirm` it only rehearses
the move. Publishing the gem builds it and pushes it to the registry, and is only done with
`confirm`.

<!-- prose anchor="Examples" purpose="tutorial" mentions="command:PromotionRun.promote! command:PublishingRun.publish_gem! command:Release.shipped" supports="code_file:lib/hecks/hecks/release/release.bluebook" -->
**Example: rehearse a promotion**

```sh
hecks PromotionRun.promote! lane.value=stable
```

Without `confirm.value=true` the command rehearses the move and writes nothing.

**Example: build the gem without pushing it**

```sh
hecks PublishingRun.publish_gem!
```

Builds the gem and says so. Pass `confirm.value=true` to push it to the registry.

**Example: see what has shipped**

```sh
hecks Release.shipped
```

Lists every version that was tagged, published and verified.

## Commands

Every command and query this module lists for a person, generated from its bluebook. `hecks release` prints the same list.

<!-- generated:begin cli section=release -->
### Release

One gem version: the record of what is running and what was shipped.

- `hecks Release.shipped`: Every version that was tagged, published and verified.

### PublishingRun

One release of the gem, or the rehearsal of it: judged by the facts, then carried out.

- `hecks PublishingRun.publish! [--gem-only] [--npm-only] [--npm-local] [--no-wait] --confirm`: Tag the merged release commit, publish the gem, and get the client package published
- `hecks PublishingRun.publish_gem! --confirm`: Build the gem and push it to the gem registry, with the key the vault holds

### PromotionRun

One move of a lane onto a commit, or the rehearsal of it: judged by the facts, then carried out.

- `hecks PromotionRun.watch! <lane>`: Fault when a lane has stood behind the lane it follows for longer than its Lane row allows
- `hecks PromotionRun.promote! <lane> [commit=] --confirm`: Move a lane onto a commit that has passed every required check, or with no --confirm rehearse the move

### Registry

A bluebook registry repository: packages versioned in it and released as tags.

- `hecks Registry.release! <package> [root=]`: Tag a package of this registry at the version its bluebook.yml carries
- `hecks Registry.check [<root>]`: Judge every package against its latest release: a changed package needs a newer version and a changelog entry.
- `hecks Registry.digest <package> [root=]`: Print a package's content digest and shape labels, as its bluebook.lock records them.

### Package

One package of the bluebook registry, vendored into a project and pinned.

- `hecks Package.vendor! <package> [from=] [root=]`: Pin a package of the bluebook registry into this project, at a release or a commit
- `hecks Package.revendor! <to> [from=] [root=]`: Pin a package that was vendored before again, for the newest release or the same one
- `hecks Package.verify [<root>]`: Check every vendored package against its bluebook.lock, then describe them as the manifest a client image carries.
<!-- generated:end cli -->
