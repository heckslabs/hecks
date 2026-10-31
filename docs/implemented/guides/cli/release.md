# release

Certify, publish and pin versions. Use it to promote a lane to a commit that has passed every
check, publish the gem, and pin a registry package.

**Concept.** A lane is a branch that a release follows, such as `stable`. Promoting moves the
lane onto a commit that every required check has passed; with no `confirm` it only rehearses
the move. Publishing the gem builds it and pushes it to the registry, and is only done with
`confirm`.

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
hecks query Release.shipped
```

Lists every version that was tagged, published and verified.
