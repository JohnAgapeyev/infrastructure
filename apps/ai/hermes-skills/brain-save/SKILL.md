---
name: brain-save
description: Save a durable second-brain note into OpenViking (viking://~/resources/brain/...). Use when the user asks to keep/save/remember something as a note for the long term, or when the conversation produces durable knowledge worth persisting. Do NOT use for quick facts or preferences about the user - those belong to the openviking memory provider (viking_remember or plain memory) instead.
---

# Saving a second-brain note

Run the bundled script with a kebab-case topic and slug, and the markdown
body on stdin (or from a file):

    /opt/data/skills/brain-save/brain-save.sh <topic> <slug> [file|-]

Examples:

    # body on stdin
    echo "# Server room label printer quirks ..." | \
      /opt/data/skills/brain-save/brain-save.sh homelab label-printer-quirks

    # from a file the terminal toolset just wrote
    /opt/data/skills/brain-save/brain-save.sh projects k3s-upgrade-notes /tmp/notes.md

## Conventions

- `topic`: short kebab-case area (`homelab`, `projects`, `recipes`,
  `people`, ...). The note lands at
  `viking://~/resources/brain/<topic>/<date>-<slug>.md`.
- Start the body with a `# title` heading, then the content in markdown.
- One note per subject; if a note on the same subject already exists,
  search for it first (`viking_search`) and ask the user whether to
  replace (re-run the script with the same slug) or create a new one.
- The human curates these notes in OpenViking Studio: they may edit or
  delete them. Deletion means "gone from your knowledge" - do not silently
  re-save deleted content; ask first.

## What the script does

It POSTs to OpenViking's content-write API (`/api/v1/content/write`) with
the `OPENVIKING_API_KEY` from `/opt/data/.env`, so parent directories are
created automatically and semantic/vector indexing refreshes server-side.
The URI is printed on success.
