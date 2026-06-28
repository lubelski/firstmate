---
name: sitrep
description: Print a one-shot, captain-facing status roll-up of the whole fleet. Use when the captain invokes /sitrep (e.g. "/sitrep", "sitrep", "where do things stand", "give me a status report"), optionally with a number to drill into one item (e.g. "/sitrep 3"). Renders the deterministic report from bin/fm-sitrep.sh verbatim - what needs your attention, what is building, what is queued, and what landed recently - then offers to confer on anything awaiting a decision.
user-invocable: true
---

# sitrep

A one-shot, attention-first status roll-up of the whole fleet.
All the work - reading canonical fleet state, classifying it, and translating it
into plain captain-facing outcomes - lives in `bin/fm-sitrep.sh`.
This skill is thin on purpose: run that script and relay its output.
**Do not re-derive, re-narrate, or second-guess the state yourself** - the script
is the deterministic source of truth, and re-interpreting it would defeat that.

## What it does

1. **Run the roll-up:**
   ```sh
   bin/fm-sitrep.sh
   ```
   It prints a clean text report with four sections, most-urgent first:
   - **FLAGGED** - items that need the captain (waiting on a decision, blocked,
     in trouble, or ready for review/merge).
   - **IN FLIGHT** - work actively running, with what each piece is doing.
   - **ON APPROACH** - queued work, with what each item is waiting on.
   - **LANDED** - a single line: how many changes shipped in the last hour.

   Every FLAGGED / IN FLIGHT / ON APPROACH line carries a `[n]` handle.

2. **Drill into one item** when the captain asks about a specific number
   (`/sitrep 3`) or wants more on something the roll-up surfaced:
   ```sh
   bin/fm-sitrep.sh <n>
   ```
   This expands item `n` - its status, the underlying task, any review link, a
   next-action hint, and its recent raw updates.

3. **Print the script's output to the captain verbatim.**
   The report is already captain-facing and deterministic; pass it through as-is.
   Do not add invented detail or restate the fleet from memory.

4. **Offer to confer on what needs a decision.**
   If the FLAGGED section is non-empty, close with a short, plain-language offer
   to dig into any flagged item (by its `[n]`) or to act on it - merge a
   ready change, unblock a stuck one, or talk through a pending decision.
   If everything is quiet, just say so.

The script is read-only: it renders state and never changes it. Acting on a
flagged item (merging, unblocking, deciding) still follows the normal lifecycle
and the captain's standing approval rules.
