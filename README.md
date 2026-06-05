# Discworld Vitals

Vitals for Discworld MUD, showing an XP information, shielding
indicators (EFF / CCC / BUG / MS / TPA), and HP / GP / Burden bars.

## A note on cross-plugin events

This plugin has an optional dependency on [discworld-magic](https://github.com/wizardquack/mallardx-discworld-magic) for receiving shielding event data. If you don't have it, no harm done, but if you, Vitals will automatically subscribe to shielding events from the Magic plugin.
