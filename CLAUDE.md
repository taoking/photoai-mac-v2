# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This is the v2 rewrite of PhotoAI Mac, a personal photo-culling workbench and preview archive for
photos spread over many SD cards and external disks. v1 lives in `../photoai-mac` and must not be
modified from here. Milestones M1–M6 are done and released as 0.6.0; the user accepted the project and it is released as
1.0.0. All later work (feedback, leftover checks, new features) is managed as a backlog and iterations in
`docs/迭代.md`.

## Layout

User-facing docs live at the root: `安装与部署.md` (requirements, install, upgrade, data location,
backup, uninstall) and `功能说明.md` (feature manual, shortcut table, versions). Developer docs live
under `docs/` (index: `docs/README.md`): `docs/交接.md`, `docs/迭代.md`, design docs in `docs/设计/`,
process records in `docs/记录/` (plan, discussion log, validation records `验收/`, reviews `审查/`), and
the frozen web prototype in `docs/原型/`. `Scripts/` holds build, install, release, model and icon
scripts; scenario and performance scripts are in `Scripts/test/`. Supported system: macOS 27.2 or later
(the toolchain only targets up to 27.0, so `Package.swift` stays at `.v27`).

## Start here

Read `docs/交接.md` first: current step, the concrete next step, which v1 files are worth consulting, the
document map, and the rules that are easiest to break. The authoritative design is
`docs/设计/设计稿.md`; when it conflicts with the detail docs in `docs/`, the design doc wins and the
detail doc gets corrected. External review reports and how each finding was resolved live in `docs/记录/审查/`.

## Keeping the docs alive

The user starts new sessions from this directory, so the docs are the only memory between
sessions. Before ending any piece of work:

- append the discussion round to `docs/记录/沟通记录.md`, quoting the user's own words;
- fold any decision into `docs/设计/设计稿.md` (and the matching detail doc);
- tick progress and add a line to the progress log in `docs/记录/计划.md`;
- update "现在在哪一步" and "下一步" in `docs/交接.md`;
- when a feature, shortcut or install step changes, update `功能说明.md` / `安装与部署.md` at the root.

Each iteration gets its own branch (`iter-<n>-<主题>`; milestones used `m1-volumes-import`, …), conventional
commits, a validation record `docs/记录/验收/I-<n>-<主题>.md` marking every check PASS / NOT RUN / BLOCKED with evidence, and a PR
the user merges. Performance targets PF-1…PF-12 in `docs/记录/计划.md` are acceptance items.

## Prototype

**Frozen (user decision, 2026-11-20).** `docs/原型/index.html` was the interaction reference up to M6;
from 0.6.0 on the native app is the reference and the prototype is no longer updated (the people page,
inspector histogram/navigator and focus box are not in it). It still opens with `open docs/原型/index.html`
and `docs/原型/tests/run.sh` still runs its scenario, but do not extend it. Native interactions are
validated with the in-app scenarios (`PHOTOAI_SCENARIO`, see `docs/交接.md`).

## Conventions

All docs, UI strings and comments are Chinese; type and member names are English. The repository is
public: never commit photos, RAW files, signing config, Team IDs or full home-directory paths.
