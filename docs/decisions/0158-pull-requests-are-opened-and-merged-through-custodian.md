# Pull requests are opened and merged through Custodian

**Status:** Accepted.
Date: 2026-10-29.

## Context

Custodian runs a domain's repository work through its own commands: `Landing` merges a branch
onto local `main`, and `PushTrain` pushes `main` to its remote. Opening and merging a pull request
on GitHub were still done by hand, with `gh`, outside the record. A project that works through
Hecks commands could not do its review step through them.

GitHub is the only place a pull request can be opened or merged, and this repository already
reaches GitHub through `gh` (`GithubRulesets`, `FindingGithub`). Calling the GitHub REST API directly
would mean a second token to manage, and nothing here needs one.

## Decision

Custodian gains a `PullRequest` aggregate with three requests and a read:

- `Open` records a request to open a pull request from a branch onto a base (`main` by default).
  The `GitHubPullRequests` port's `Create` asks GitHub; the answer records the number and URL.
- `Merge` records a request to squash-merge a pull request by its number. The port's `Squash`
  asks GitHub; the answer records the merge.
- `Status` is a query that answers a pull request's number, state, URL, merge and checks as text.

The adapter, `GithubPullRequests`, runs `gh` through an injectable runner. A merge is always
`gh pr merge --squash`. `--admin` is never passed, so a branch protection rule is not bypassed.

A refusal from `gh` is recorded as a refusal with its message, never retried.

## Consequences

- A pull request is opened and merged through the same record as the other repository work, so it
  can be read back with `Status` and audited.
- The adapter runs in the current directory, as `GithubRulesets` does. A caller in another
  checkout must `cd` there first, or the operation is run from that checkout.
- The squash-only rule is the adapter's, not the aggregate's. A change to it is a change to the
  adapter, and its spec pins `--admin` out.
- Merging on GitHub does not land the commit on local `main`. A caller that wants the local merge
  still runs `Landing`, then `PushTrain`.
