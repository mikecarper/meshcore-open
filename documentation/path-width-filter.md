# Path-width forwarding filters

In the repeater CLI, tap the filter icon to prepare a rule for all packets using
1-, 2-, or 3-byte path hashes (or any width). **2+ bytes (2 or 3)** matches both
larger supported widths with one rule and one shared per-minute allowance.
The width is encoded in the packet,
so it also matches zero-hop packets. Four-byte path hashes are unsupported.

Choose the admission path and either drop matching packets or limit forwarding
per minute. The dialog only fills the CLI input: review and press Send yourself.
Use `get fr` to inspect existing rules first. The unnumbered setter adds in a free
slot without overwriting an occupied rule; it fails if the table is full.

Examples for firmware with the new width selector:

```text
set fr any pb=1 d
set fr any pb=2 q=10
set fr any pb=2+ q=10
set fr any pb=3 m=bc d
```

The long width option is `hashbytes=any|1|2|2+|3` on `set flood.rule`. `pb=*` is the
compact wildcard. It can be combined with payload, hop, channel, incoming-scope,
and prefix conditions; a prefix must satisfy the selected width. A 2- or
3-byte prefix narrows `2+` to that exact width.

Radio rules filter flood forwarding, not direct packets or local delivery.
Bridge/crossover rules apply at the corresponding transport boundary. Dropping
or limiting all floods can disrupt relayed login/admin traffic. Rules require
updated firmware; older firmware rejects the new option. Remove width-only
rules before downgrading firmware, as older readers may reset the saved table.

Use `get fr.N` for a copyable saved rule and `del fr.N` to remove that slot. The
browser [filter playground](https://mikecarper.github.io/MeshCore/filter_tool/)
also supports width matching; its policy-language exports are design previews,
not installable firmware commands.
