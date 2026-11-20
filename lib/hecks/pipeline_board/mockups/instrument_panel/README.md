# Pipeline Board mock-up: the instrument panel

A hand-built design sample of the board's main page, for the owner to judge beside the present
board. It is one of two mock-ups (the other is `board-mock-up-as-a-signal-box`). The owner picks
one, the chosen look becomes the page projector's theme (ADR 0195), and this directory is deleted.
It declares no domain and wires no port, and nothing in Hecks loads it.

## Open it

```sh
ruby lib/hecks/pipeline_board/mockups/instrument_panel/serve.rb
```

Then open <http://127.0.0.1:4757/>. The staged bad day has its own address,
<http://127.0.0.1:4757/#bad-day>, and the switch at the top right changes between the two.

Stop it with Ctrl-C, or from another shell:

```sh
pkill -f mockups/instrument_panel/serve.rb
```

The present board on :4747 is not touched. `serve.rb` serves the four static files and passes
`GET /api/state` through to `http://127.0.0.1:4747/api/state`, because the board sends no CORS
header and a page on another port cannot read it from the browser. That one read is all it sends
the board. The page reads again every 10 seconds.

## The design

A calm instrument panel: dark, few colours, large numbers, small labels. Colour appears only on a
reading that is wrong, amber for attention and red for failed, so a healthy board is nearly
monochrome. A red main is one full-width red band that nothing else on the page resembles.

Top to bottom:

1. **The pipeline.** The strip of stages, with Signalbox's signal as a reading in words, and under
   it the fill saying why the waiting items did not start.
2. **Stuck.** Two groups, "waiting on a person" and "standing too long". Each entry is one line
   naming who it waits on by role or name. The page never says "you".
3. **The line.** A Work item's route as a track: planned, admitted, running, reviewed, landed, on
   the train, on main. Every item in flight is a mark at its place, and a stop says why it is held.
4. **Today.** A time strip with red episodes and how each ended, the spans where admission was
   closed, and each landing and train as a mark.
5. **Everything else**, collapsed.

Every box shows a count and one line. Ids, shas and full text sit behind a click. A failed reading
is said once, in one line under the header.

## What is real and what is staged

On **Real state** every reading comes from the board's `GET /api/state`, except the ones no query
answers yet. Those show invented values with a visible `staged` mark:

- the **admitted** and **reviewed** places on the line (the state tells planned and started apart,
  nothing finer);
- the spans where **admission was closed**;
- the **landings** of the day, when the state holds no landing time (today it holds none);
- how a red episode **ended**: a real one says only that CI went green.

Real readings worth knowing about when judging:

- Red episodes are derived from the last 20 CI runs on main, not from Deliver's RedEpisode.
- The stuck list adds the "Overdue" stage's items and the parked integration runs to the board's
  own stuck entries, all as waiting on the owner.
- The fill reading is whatever the board holds; it is dated in the line when it is over an hour old.

On **Staged bad day** everything is invented (`staged.js`): main red with an episode being
reverted, load short and admission closed since 14:02, three entries waiting on a person and two
standing too long. The strip, the stuck list and the fill are staged in the shape of
`/api/state` and drawn by the same code as the real ones; the line and the day are staged as the
panel draws them.

## Throwing it away

After the pick, delete this directory, and with it the branch
`board-mock-up-as-an-instrument-panel` and its `ci/board-mock-up-as-an-instrument-panel` branch
and draft pull request. Nothing here is meant for `main`.
