---
name: fact-share
description: Save a deliberately neutral, curated fact to the shared facts directory (viking://resources/general-facts/) for read-only use by other memory-isolated profiles. Use when the user asks to share or sync a fact across profiles, or when a fact should outlive this profile's own memory namespace. Do NOT use for profile-private memories (viking_remember or plain memory instead) or long-form notes (brain-save instead).
---

# Sharing a curated fact

Run the bundled script with a kebab-case slug and the fact on stdin
(or from a file):

    /opt/data/skills/fact-share/fact-share.sh <slug> [file|-]

Examples:

    # body on stdin
    echo "# Communication style - John wants BLUF..." | \
      /opt/data/skills/fact-share/fact-share.sh communication-style

    # from a file the terminal toolset just wrote
    /opt/data/skills/fact-share/fact-share.sh health-basics /tmp/fact.md

## Conventions

- One fact per note. Phrase it so it is safe for any reader that has
  been granted read access: neutral, factual, self-contained
  ("User prefers X"). If a fact cannot be phrased neutrally, it is not
  a shared fact - keep it in profile-private memory.
- Notes land at `viking://resources/general-facts/<date>-<slug>.md`.
- Readers get read-only access by the operator (`ov acl grant`); this
  profile owns writes to the directory.
- The human curates these notes in OpenViking Studio and may edit or
  delete them; do not silently re-save deleted content.

## What the script does

It POSTs to OpenViking's content-write API (`/api/v1/content/write`)
with the `OPENVIKING_API_KEY` from `/opt/data/.env`, so parent
directories are created automatically and semantic/vector indexing
refreshes server-side. The URI is printed on success.
