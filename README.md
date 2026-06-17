# Discworld Vitals

Vitals panel for Discworld MUD, with:

- HP / GP / burden bars
- XP, XP/hr, and XP/hr over time chart
- realtime shielding indicators (EFF / CCC / BUG / MS / TPA)

Additionally this plugin provides skill-, stat-, and xp-aware goal
tracking for your characters. Enter /goals to get started.

## A note on cross-plugin events

This plugin has an optional dependency on
[discworld-magic](https://github.com/wizardquack/mallardx-discworld-magic)
for receiving shielding event data. If you don't have it, no harm
done, but if you, Vitals will automatically subscribe to realtime
shielding events from the Magic plugin.

## Credit

Many thanks to Quow and Oki, whose work on similar plugins was
invaluable in designing and building this one.
