# Discworld Vitals

Vitals panel for Discworld MUD, with:

- HP / GP / burden bars
- XP, XP/hr, and XP/hr over time chart
- realtime shielding indicators (EFF / CCC / BUG / MS / TPA)

Additionally this plugin provides skill-, stat-, and xp-aware goal
tracking for your characters. Enter /goals to get started, or /skill
&lt;skill&gt; to inspect a single skill's level, bonus, and the stats that
feed it — add an optional number (e.g. /skill ma.sp.of 550) to see what
level a target bonus needs and what bonus a target level gives, with a
one-click "add goal" for either.

## A note on cross-plugin events

This plugin has an optional dependency on
[discworld-magic](https://github.com/wizardquack/mallardx-discworld-magic)
for receiving shielding event data. If you don't have it, no harm
done, but if you, Vitals will automatically subscribe to realtime
shielding events from the Magic plugin.

Vitals also **emits** `net.mallard.discworld.gp.full` (payload
`{ subject = "self", gp, maxgp }`) the moment your GP refills to
maximum, so peer plugins can react — e.g. resume casting. It fires once
on each refill to full (edge-triggered on the not-full → full
transition), the complement of the inbound
`net.mallard.discworld.gp.zero` event Vitals subscribes to.

## Credit

Many thanks to Quow and Oki, whose work on similar plugins was
invaluable in designing and building this one.
