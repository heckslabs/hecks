# Signal box mock-up

A hand-built mock-up of the Pipeline Board's main page as a railway signal box, made to be compared
with the instrument panel mock-up and thrown away once the owner has picked. It is not part of the
board: it reads `GET /api/state` from the board on :4747 through a relay and changes nothing.

- **Address:** <http://localhost:4749/> for real state, <http://localhost:4749/?day=bad> for the
  staged bad day. The switch in the header changes between them.
- **Start:** `bundle exec ruby lib/hecks/pipeline_board/mockups/signal_box/serve.rb`
  (`PORT=4750` picks another port).
- **Stop:** `pkill -f mockups/signal_box/serve.rb`, or Ctrl-C where it runs.

The relay exists because the board sends no `Access-Control-Allow-Origin` header, so a page on
another port cannot read its state from the browser.

Readings no query answers yet are staged and tagged `staged` where they are drawn: in the real-state
view these are the span of closed admission and the entry at the `reviewed` station. On the staged
bad day every reading is staged.

The staged bad day is the instrument panel mock-up's day, value for value (its `staged.js` at commit
75bf8886f), so the two designs can be compared on the same numbers: the clock stands at 15:10, main
has been red since 13:41 in the third episode of the day, admission has been closed since 14:02 with
load 21.4 over a limit of 16, three entries wait on a person and two have stood too long.

Screenshots of both views are handed over with the result, not kept here: a spec reads every file
under `lib/hecks/pipeline_board` as text.

## Throwing it away

After the pick, in this order:

1. Stop the server: `pkill -f mockups/signal_box/serve.rb`. It serves from this worktree, so
   removing the worktree first leaves it serving deleted files.
2. Delete this directory.
3. Remove the branch `board-mock-up-as-a-signal-box` and its worktree.
4. Delete the branch `ci/board-mock-up-as-a-signal-box` on origin and close its draft pull request.

Nothing here is meant for `main`.
