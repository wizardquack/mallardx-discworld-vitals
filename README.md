# Discworld Vitals

A Mallard flagship plugin for Discworld MUD. Custom-HTML panel
(`ui/vitals.{html,css,js}`) showing an XP card, an arcane-shield chip
row (EFF / CCC / BUG / MS / TPA), and HP / GP / Burden bars.

## Install (dev)

```sh
bash scripts/reinstall.sh
```

Then restart Mallard or toggle the plugin in the manager.

## What it does

The plugin maintains a single state snapshot on the Lua side and pushes
the whole snapshot to the iframe via `panel:post("state", …)` on every
mutation. Updates flow in from three sources:

- **MXP entity pushes** (primary real-time path) — `hp`, `maxhp`, `gp`,
  `maxgp`, `burden`, `xp` entities are emitted by Discworld after every
  command when MXP is enabled.
- **`char.vitals` GMCP frame** — authoritative HP/GP/burden/XP on login
  (and periodic refreshes on some Discworld configs).
- **Score-brief text trigger** — fallback path for users who have
  disabled MXP in their Discworld settings.

XP/hour is computed over a rolling window (configurable: 5 min / 30 min
/ 1 h) by `xp_tracker.lua`. GP regen between authoritative updates is
predicted optimistically by `gp_tracker.lua` and reconciled when a real
source arrives.

## Auto-enable

`[worlds] match = ["discworld.starturtle.net:*"]` — the plugin is enabled
by default when you connect to a world whose host matches that pattern;
no-op on other worlds.

## Cross-plugin events

This plugin subscribes to `net.mallard.discworld.shield.up`,
`net.mallard.discworld.shield.down`, and `net.mallard.discworld.shield.cleared`
(filtering for `subject == "self"`) and drives all five chips — EFF,
CCC, BUG, MS, TPA — from those events. Detection itself lives in
[discworld-magic](https://github.com/wizardquack/mallardx-discworld-magic);
this plugin just renders the state and formats each chip's hover-tooltip
detail.

| Chip | Up tooltip detail               |
|------|---------------------------------|
| EFF  | floater item (if known)         |
| CCC  | substance · strength/5          |
| BUG  | size cloud of bugs              |
| MS   | deity · strength                |
| TPA  | percent% · glow · age (1s tick) |

On `shield.cleared` every chip is reset to "down"; subsequent
`shield.up` events repopulate whatever's actually active. That signal
fires today on "You do not have any arcane or divine protection."

(Prior to 2026-05-28 these were `net.mallard.discworld.tpa.up/.down`
and `…eff.up/.down`. The unified surface was introduced alongside the
discworld-grouping shield-row work.)

## Design

Full design lives in the [Mallard repo](https://github.com/wizardquack/mallard) under `docs/superpowers/specs/2026-05-18-discworld-flagships-vitals-chat-design.md`.
