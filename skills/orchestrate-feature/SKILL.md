---
name: orchestrate-feature
description: Use when a feature is too large for one session and will be split across child sessions and subagents — at plan approval, before spawning any session, after each child session starts, and at every gate. Also when a spawned session turns out to be on the wrong model, subagent context is dwarfing the work it does, or the 5-hour usage window is running out mid-feature.
---

# Orchestrating a feature across sessions

## Overview

One Fable session orchestrates. Opus child sessions each own one plan section in their own
worktree. Subagents do task-level work on the cheapest model that fits. The orchestrator
briefs, gates, rules and relays; it never implements and never reads a child's code.

Cost is dominated by context re-read per message, not by output: a child sitting at 300k
context pays 300k on every turn, and a subagent handed the whole plan pays 150k+ per turn
for a ten-line answer. Every rule below exists to keep contexts small and models matched to
the work.

## Tiers

| Tier | Model | Effort | Output style | Set by |
|---|---|---|---|---|
| Orchestrator (this session) | Fable | high | any | Morgan at session start |
| Child session (one per plan section) | `claude-opus-5-5` | `high` | `Trim` | post-spawn checklist |
| `reviewer` subagent (spec/quality review, design choice, root cause) | Opus | high | n/a | `~/.claude/agents/reviewer.md` |
| `implementer` subagent (one task with its tests) | Sonnet | medium | n/a | `~/.claude/agents/implementer.md` |
| `mechanic` subagent (edits from an exact spec) | Haiku | low | n/a | `~/.claude/agents/mechanic.md` |
| `scout` subagent (read-only lookup) | Haiku | low | n/a | `~/.claude/agents/scout.md` |

Spawned sessions inherit the parent's model, effort and output style. Nothing sets them
correctly except the checklist below.

## Procedure

1. **Plan.** The approved plan gets an `## Orchestration` section (template below): one
   child per section, one worktree per child, numbered gates. Rulings are appended to the
   plan, numbered, as they are made.
2. **Spawn.** One `spawn_task` chip per child; the chip prompt is the brief (template
   below). Morgan clicks each chip.
3. **Post-spawn checklist**, per child, after its first turn and before its first task.
   Read `get_session`; then, for each field not already right:
   - `set_session_model` → `claude-opus-5-5`
   - `set_session_effort` → `high`
   - `set_session_output_style` → `Trim`
   - `get_session` again: all three must read back. A denied switch is left for Morgan;
     say so in the next message to them.
4. **Gate loop.** A child stops at each gate and reports in ten lines. The orchestrator
   checks the report against the plan section, answers open questions with a ruling
   appended to the plan, and relays the next gate. Cross-session facts (a SHA another child
   must rebase onto, a port, an API restart) are relayed by the orchestrator, never
   discovered by the children.
5. **Budget at every gate.** `get_usage`. Past 80 % of the 5-hour window: tell children
   that have not started a task to wait, and run the remaining children one at a time. The
   window resets on a clock; a waiting session costs nothing.
6. **Compaction at every gate.** The gate relay includes:
   `/compact keeping only your plan section, the rulings, commit SHAs, and open items`.
7. **Finish.** Merge the worktree branches back into master; Morgan pushes or dcommits.

## Brief template (the chip prompt)

```
You are S-<NAME>, one of <n> sessions building <feature>. Plan:
<repo>/docs/superpowers/plans/<date>-<feature>.md — your part is "Section <X>".
Before your first task, copy Global Constraints, Rulings, Shared contract and
Section <X> into docs/superpowers/plans/<date>-<feature>-<name>.md in your
worktree and commit it.

Model policy: you run on Opus at high effort. Subagents are dispatched by agent
type — scout (lookup), mechanic (edits from an exact spec), implementer (a task
with tests), reviewer (spec + quality review). Never fable. A subagent gets the
task text and file list, never the plan file.

Method: superpowers:subagent-driven-development, one task per implementer. One
reviewer pass per task; two (spec, then quality) only when the task changed a
shared interface. Subagents reply in ten lines.

Gates: stop at each G<n> in the plan's Orchestration section. Report in ten
lines: commits (SHA + subject), test results as counts, open questions each
with a recommended answer. Then compact, keeping your section, rulings, SHAs
and open items.

Rules: stage and commit only, never push; no attribution trailers; ask the
orchestrator on anything the Rulings do not cover, with a recommended answer;
never re-open a decided item.
```

## Orchestration section template (goes in the plan)

```
## Orchestration

| Session | cwd / worktree | Plan section | Starts |
|---|---|---|---|
| S-API "<feature> — <part>" | <repo> (worktree) | Section C | on approval |
| S-RENDER "<feature> — <part>" | <repo> (worktree) | Section A | on approval |
| S-HOST "<feature> — <part>" | <repo> (worktree off S-RENDER's types commit) | Section B | after G3 |

Gates (a session stops at each and reports in ten lines):
G0 plan approved · G1 <observable fact> · G2 <observable fact> · … · Gn merge
of the worktree branches into master.
Rulings protocol: a session that hits an ambiguity asks the orchestrator with a
recommended answer; it never guesses silently and never re-opens decided items.
Compaction points: after each gate.
```

## Reading usage

The app reports account-wide windows and this session's context, never per-session spend.
To attribute cost, scan `~/.claude/projects/*/*.jsonl` (child sessions live under their
worktree's project folder), dedupe by message id, and sum each assistant message's `usage`
by `model` and by the `isSidechain` flag (subagent lanes). Cached reads × message count is
the number to watch.

## Red flags

| Seen | Meaning |
|---|---|
| A child's `get_session` shows `fable`, `xhigh`, or `Explanatory` | Checklist step 3 was skipped; fix before its first tool call |
| A subagent's brief pastes a plan section | It pays for the plan on every turn; give it the task text |
| Three review passes on a Sonnet task | Two are for shared-interface changes only |
| A child above 250k context between gates | It missed a compaction; send the compact line now |
| Parallel heavy runs (e2e baselines, full suites) at 90 % of the window | Sequence them or wait for the reset |
| "I'll just do this small fix myself" (orchestrator) | Spawn a chip; the orchestrator's context is the most expensive one to grow |
