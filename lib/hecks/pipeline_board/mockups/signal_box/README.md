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
