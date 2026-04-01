---
name: humanizer-writing
description: "Write natural, human-sounding documentation, commit messages, PR descriptions, and prose. Strips robotic phrasing, filler words, and over-formality. Use when drafting or revising any written content that should read like a person wrote it."
---

# Humanizer Writing

## Goal
Produce written content that sounds like a real developer wrote it — clear, direct, and natural. No corporate fluff, no robotic hedging, no unnecessary formality.

## Use this skill when

- Writing or revising documentation, READMEs, or usage guides
- Crafting commit messages or PR descriptions
- Editing any prose that sounds stiff or AI-generated
- Reviewing content for tone and readability

## Do not use this skill when

- Writing code or configuration files
- Generating structured data (JSON, YAML schemas)
- The task is purely technical with no prose component

## Anti-patterns to eliminate

These phrases and habits make writing sound robotic. Remove or replace them:

| Robotic pattern | Human alternative |
|---|---|
| "It's important to note that..." | Just state the thing |
| "This allows you to..." | "You can..." |
| "In order to..." | "To..." |
| "Leverage" | "Use" |
| "Utilize" | "Use" |
| "Facilitate" | "Help" or "let" |
| "Ensure that" | "Make sure" or just drop it |
| "It should be noted" | Delete entirely |
| "As mentioned above/previously" | Delete or link directly |
| "Please note that" | Delete entirely |
| "Going forward" | Delete or say "from now on" |
| "At this point in time" | "Now" |
| "Due to the fact that" | "Because" |
| "In the event that" | "If" |
| Starting every paragraph with "This..." | Vary sentence openers |

## Workflow

1) Read the draft or content to revise
2) Flag robotic patterns
   - Scan for the anti-patterns above
   - Look for passive voice where active is clearer
   - Check for unnecessary hedging ("might", "could potentially", "it is possible that")
   - Spot filler transitions ("Additionally", "Furthermore", "Moreover")
3) Rewrite with these principles
   - **Short sentences win.** If a sentence has two ideas, split it.
   - **Active voice by default.** "The function returns X" not "X is returned by the function."
   - **Say it once.** Don't repeat the same point in different words.
   - **Be specific.** "Runs in 0.8s" beats "runs quickly."
   - **Start with the action.** Lead with what the reader should do or know.
   - **Use contractions.** "Don't" over "do not" in docs. "It's" over "it is."
   - **Cut the warm-up.** Delete the first sentence if the second one works as an opener.
4) Read it out loud (mentally)
   - If it sounds like a person talking to a colleague, it's good.
   - If it sounds like a press release or academic paper, cut more.

## Commit message guidelines

Good commit messages are terse and specific:

```
# Good
fix: stop double-firing lifecycle hooks on aggregate save

# Bad
fix: This commit fixes an issue where lifecycle hooks were being fired
twice when saving an aggregate, which could potentially cause problems
```

Rules:
- Subject line under 72 characters
- No period at the end of the subject
- Body explains "why", not "what" (the diff shows what)
- No filler like "This commit..." or "This PR..."

## Documentation guidelines

- Lead with what the reader can do, not what the system is
- Show a code example in the first 5 lines
- Use second person ("you") not third person ("the user")
- One idea per paragraph, three sentences max
- Headers should be scannable — a reader skimming headers should get the gist

## PR description guidelines

- First line: what changed and why, in one sentence
- Bullet the specific changes (3-5 max)
- Include a before/after if behavior changed
- Skip the preamble — no "This PR..." opener

## Deliverable

Provide:
- the revised text
- a short list of what changed and why (so the author learns the patterns)
