# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This is the v2 rewrite of PhotoAI Mac, a personal photo-culling workbench and preview archive for
photos spread over many SD cards and external disks. v1 lives in `../photoai-mac` and must not be
modified from here. The clickable prototype (P0) is approved; there is no native code yet and the
next step is milestone M1 in `docs/计划.md`.

## Start here

Read `交接.md` first: current step, the concrete next step, which v1 files are worth consulting, the
document map, and the rules that are easiest to break. The authoritative design is
`docs/设计稿.md`; when it conflicts with the detail docs in `docs/`, the design doc wins and the
detail doc gets corrected.

## Keeping the docs alive

The user starts new sessions from this directory, so the docs are the only memory between
sessions. Before ending any piece of work:

- append the discussion round to `docs/沟通记录.md`, quoting the user's own words;
- fold any decision into `docs/设计稿.md` (and the matching detail doc);
- tick progress and add a line to the progress log in `docs/计划.md`;
- update "现在在哪一步" and "下一步" in `交接.md`.

Each milestone gets its own branch (`m1-volumes-import`, …), conventional commits, a validation
record `docs/验收/M<n>-<主题>.md` marking every check PASS / NOT RUN / BLOCKED with evidence, and a PR
the user merges. Performance targets PF-1…PF-12 in `docs/计划.md` are acceptance items.

## Prototype

`prototype/index.html` is a single self-contained file (vanilla JS, no network, mock data) and is the
interaction reference for the native app. Open it with `open prototype/index.html`. After changing
it, run `prototype/tests/run.sh`, which injects `tests/scenario-harness.html` into the page, drives the
typical culling scenario in headless Chrome and prints PASS/FAIL lines; extend the harness when adding
interactions.

## Conventions

All docs, UI strings and comments are Chinese; type and member names are English. The repository is
public: never commit photos, RAW files, signing config, Team IDs or full home-directory paths.
