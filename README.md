# Annotate for Tern

Comment on a snapshot of any Tern block (an agent's reply, a file, a web page, a terminal), then send the edit comments to an agent on demand or in batches. Questions go to Carly and her answer is saved in the comment's thread. To-dos become cards on a Markdown board.

**Status: prototype.** Written on Windows 11 with Tern 0.8.3. It works, but it fights the plugin API in several places (see [Limits](#limits)); the point of publishing it is to show the workflow, and to ask for it as a built-in Tern feature: <https://github.com/stencil-hq/tern-sdk/issues> (search "Annotate any block").

## Why

Agents produce a lot of text, and most of it is not mine to rewrite wholesale: a paragraph is wrong, a claim needs a source, a sentence is outside my preferences. The usual loop is to retype a new prompt that quotes the passage. Annotate lets me read, leave anchored comments (edit / question / note / to-do) as I go, and send them as one batch, without losing my place or producing yet another document in the folder.

## Install

```sh
tern plugin install github.com/hyper-stition/tern-annotate
```

Then reload plugins. Give it about half a minute: modules are compiled one per timer tick after startup, and commands say "Annotate is still starting" until they are ready.

## Use

| Command | Chord | Does |
| --- | --- | --- |
| Annotate this block… | `ctrl+alt+a` | Opens (or refreshes) the review of the focused block, docked beside it |
| Annotate copied text… | `ctrl+alt+g` | Highlight text, copy it (Ctrl+C), run this, paste it (Ctrl+V) into the prompt: the comment is on exactly that passage |
| Open annotation review… | | Reopens a review (they persist) |
| Send pending annotation comments | | Sends the open edit comments to an agent |
| Copy annotations as Markdown… | | Exports a review |
| Delete an annotation review… | | Removes a review and its files |
| Add to-do… | `ctrl+alt+t` | Adds a card to the to-do board |
| Open general to-do (floating) | `ctrl+alt+b` | Floats the board |

In a review panel, click a paragraph to comment on it, or right-click it for *Request edit / Ask question / Add note / Add todo*. Click a comment to reply, resolve, send it, make it a to-do, or delete it. The panel's buttons cycle the send mode (manual, immediately, batched), refresh the review from its source, page through long sources, and copy Markdown.

Comment text is one line (Tern's prompt is single-line); use replies for more.

Sources: agent chats are read from the omp transcript; files from their live buffer; web pages by fetching the page's address and converting the HTML to text (no JavaScript runs, so script-only pages come up empty; use *Annotate copied text* there); everything else from the block's text. Sources are cut to 60,000 characters.

To-dos go to `~/general-todo.md` by default (any Tern board file; set the `general_board` key in the plugin's `kv.json` to change it).

States: `open`, `asking`, `answered`, `sent`, `applied`, `resolved`, `filed`. A sent edit becomes `applied` when its agent finishes. *Refresh* re-attaches comments to the new text by unit id, then by quote.

## Data

`<state>/plugin-data/annotate/`: `artifacts/<id>.json` (comments), `artifacts/<id>.units.json` (the snapshot), `kv.json` (index). Changes are written 250 ms after they happen.

## Limits

Found while building it; each one shaped the code.

- **Window hooks have a 50 ms budget and a trip disables the hook until reload.** Tern compiles every loaded chunk (`require` measured 15-29 ms per small module in my window, against 1.5-6 ms to compile the same source with `loadstring`), so the code is split into small modules, loaded with `loadstring`, one preload step per timer tick. Timers only run while the window draws, so startup can take 20-40 s. If the plugin's timers stop for minutes while Tern is in use, it reloads itself (at most every ten minutes).
- **Starting a process costs about 41 ms** (`tern.process.run` of `cmd.exe`, measured), so the clipboard cannot be read from a command; *Annotate copied text* asks you to paste instead.
- **Plugins cannot add to the built-in right-click menu** of a terminal, chat, file or browser block, and cannot read a selection. Right-click works inside the review panel only.
- **`cx.browser` needs macOS or Linux** ("browser automation needs Tern on macOS or Linux"), hence the HTTP fetch for pages on Windows.
- Reloading the plugin within 250 ms of a change loses that change.

## Layout

`window.luau` registers commands and handlers and preloads the modules. `core`, `anchor`, `prompts`, `html` are pure logic (plain Lua 5.4 compatible, no Tern API). `store`, `nodes`, `view`, `panel`, `sources`, `actions`, `flows`, `reviews`, `events`, `commands` use the window API. Keep the `require` graph acyclic: a cycle recurses until the budget trips.

## License

MIT.
