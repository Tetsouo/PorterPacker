# PorterPacker

Stand near a Porter Moogle, type a command, and PorterPacker drives the menus
to pack/unpack gear via storage slips.

## Commands

Aliases: `//porterpacker` | `//packer` | `//po`

### Primary

| Command               | Effect                                                       |
| --------------------- | ------------------------------------------------------------ |
| `//po`                | SWAP to current job (pack everything else, unpack current)   |
| `//po <JOB>`          | SWAP to `<JOB>`                                              |
| `//po swap [JOB]`     | Same as above (default JOB = current)                        |
| `//po u [JOB]`        | UNPACK only — alias `unpack`                                 |
| `//po p [JOB]`        | PACK only — alias `pack`                                     |
| `//po all`            | PACK ALL jobs (Active + Inactive) — alias `packall`          |
| `//po fetch`          | UNPACK ALL Active jobs — alias `unpackall`                   |
| `//po fetch inactive` | UNPACK ALL Inactive jobs                                     |
| `//po s [scope]`      | STATUS: see what is stored vs out — alias `status`, `info`   |

`scope` for status: `active` (default) | `inactive` | `all` | `<JOB>`

### Utilities

| Command                     | Effect                                                  |
| --------------------------- | ------------------------------------------------------- |
| `//po help` (or `?`)        | Show in-game help                                       |
| `//po reset` (or `unstuck`) | Force-reset state machine when blocked                  |
| `//po slips` (or `rs`)      | Return any slips left in inventory to satchel           |
| `//po export [name]`        | Export storable inventory to `data/<name>.lua`          |
| `//po export all`           | Export from every bag, name = `export_<char>_<job>.lua` |
| `//po debug on\|off`        | Toggle packet debug logging (writes to `debug.log`)     |

## Data layout

```text
data/
  <Charname>/
    config.lua              <- optional per-character config (see below)
    Active/<JOB>.lua        <- jobs you actively play
    Inactive/<JOB>.lua      <- jobs stored only, not currently played
```

`//po fetch` defaults to `Active/`; `//po all` packs both. The split lets you
keep alts/fully-stored jobs out of the unpack phase.

A data file can be either a flat list (`return { "Item A", "Item B" }`) or a
split list with separate pack/unpack sets:

```lua
return {
    pack   = { ... },  -- wide list (everything storable)
    unpack = { ... },  -- narrow list (items actually used in current sets)
}
```

### Per-character config (optional)

`data/<Charname>/config.lua` example:

```lua
return {
    ignore_bags   = { 15 },  -- bag IDs PorterPacker will not touch
    slip_home_bag = 5,       -- where storage slips live (5=satchel default)
}
```

Bag IDs: `0`=inventory, `5`=satchel, `6`=sack, `7`=case,
`8/10..16`=wardrobes 1-8.

## Credits

Originally by Ivaar, modified by Gimlic & Siyual, refactored by Tetsouo.
