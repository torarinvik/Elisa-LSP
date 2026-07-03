# Elisa highlight palette (dark theme) — OKLCH-derived

Computed in OKLCH so equal semantic distance reads as equal perceptual
distance; hue = family, hue offset = subfamily, L/C steps = leaf (see
highlight-taxonomy.md). Legend index = wire index in the semanticTokens
legend (src/semtokens.elisa) — keep all three in lockstep.

| # | token type | hex | oklch |
|---|-----------|-----|-------|
| 0 | elisa.type.int.signed | `#8CBAF7` | 0.78 0.10 255 |
| 1 | elisa.type.int.unsigned | `#82BEF4` | 0.78 0.10 247 |
| 2 | elisa.type.float | `#7AC8F5` | 0.80 0.10 235 |
| 3 | elisa.type.scalar | `#78CBE7` | 0.80 0.09 222 |
| 4 | elisa.type.string | `#6CD7E3` | 0.82 0.10 205 |
| 5 | elisa.type.container | `#73D1CA` | 0.80 0.09 190 |
| 6 | elisa.type.user | `#AED7F5` | 0.86 0.06 240 |
| 7 | elisa.type.void | `#94A8B6` | 0.72 0.03 240 |
| 8 | elisa.lit.int | `#F2B966` | 0.82 0.12 75 |
| 9 | elisa.lit.float | `#FCB26F` | 0.82 0.12 62 |
| 10 | elisa.lit.char | `#F7A97C` | 0.80 0.11 50 |
| 11 | elisa.lit.string | `#EFA187` | 0.78 0.10 40 |
| 12 | elisa.lit.value | `#CCA273` | 0.74 0.08 70 |
| 13 | elisa.fn.def | `#EBD96E` | 0.88 0.13 100 |
| 14 | elisa.fn.use | `#CDC072` | 0.80 0.10 100 |
| 15 | elisa.fn.lambda | `#C6CB75` | 0.82 0.11 112 |
| 16 | elisa.bind.param | `#88D7B9` | 0.82 0.09 168 |
| 17 | elisa.bind.local | `#8ECEAE` | 0.80 0.08 162 |
| 18 | elisa.bind.field | `#7FC9B3` | 0.78 0.08 174 |
| 19 | elisa.bind.global | `#62B995` | 0.72 0.10 165 |
| 20 | elisa.bind.discard | `#6D736F` | 0.55 0.01 160 |
| 21 | elisa.effect.grant | `#BD9FF2` | 0.76 0.12 300 |
| 22 | elisa.effect.name | `#D3A6FF` | 0.80 0.14 305 |
| 23 | elisa.effect.unsafe | `#EC7FCA` | 0.74 0.16 340 |
| 24 | elisa.effect.error | `#D491DF` | 0.75 0.13 322 |
| 25 | elisa.mem.region | `#DE9C7E` | 0.75 0.09 45 |
| 26 | elisa.mem.qualifier | `#C29376` | 0.70 0.07 52 |
| 27 | elisa.flow.branch | `#FA969F` | 0.78 0.12 15 |
| 28 | elisa.flow.error | `#EA86AF` | 0.74 0.13 355 |
| 29 | elisa.flow.concurrent | `#E093CF` | 0.76 0.12 335 |
| 30 | elisa.decl.skeleton | `#9BB0C7` | 0.75 0.04 250 |
| 31 | elisa.contract.clause | `#90D192` | 0.80 0.11 145 |
| 32 | elisa.contract.quantifier | `#85CA98` | 0.78 0.10 152 |
| 33 | elisa.contract.ghost | `#8CA78C` | 0.70 0.05 145 |
| 34 | elisa.op.mutation | `#8CE3BE` | 0.85 0.10 165 |
| 35 | elisa.op.lambda | `#C5CB7E` | 0.82 0.10 112 |
| 36 | elisa.op.range | `#D9AF75` | 0.78 0.09 75 |
| 37 | elisa.meta.decorator | `#B6A372` | 0.72 0.07 90 |
| 38 | elisa.meta.directive | `#9EA2C4` | 0.72 0.05 280 |
| 39 | elisa.meta.module | `#9EBDCC` | 0.78 0.04 230 |
| 40 | elisa.comment | `#6B7A66` | 0.52 0.03 135 |
| 41 | elisa.punctuation | `#6B7480` | 0.51 0.02 255 |
| 42 | elisa.op.arithmetic | `#C0A878` | 0.72 0.06 85 |
| 43 | elisa.op.comparison | `#8FA6B8` | 0.68 0.04 240 |
| 44 | elisa.op.logical | `#A896C4` | 0.68 0.06 295 |
| 45 | elisa.op.bitwise | `#8FB0AA` | 0.72 0.04 175 |
| 46 | elisa.op.assign | `#A6C79E` | 0.78 0.06 140 |

Indices 40–46 fill out the "universe" (every visible token colored): the
operator families sit at low chroma so they read as connective tissue while
hue still encodes meaning — assign near bindings-green, logical near effects-
violet, arithmetic warm like the value literals, comparison/bitwise cool.
Identifier bindings (params/locals/fields → bind.local, `.field` → bind.field)
and effect dotted names after `can`/`trusted` are emitted lexically. The **[S]
layer** then refines bare references against the real symbol table (parse +
collect): a name declared as a Struct/Enum/Alias → type.user, Func/Extern →
fn.use, Const → bind.global, Module → meta.module — so even a lowercase type or
a function passed as a value colors correctly.

**Comments** (index 40) are now emitted: the frontend lexer collects comment
spans in a side channel (frontend_tokenize_comments_with_len) and the LSP merges
them into the token stream by position.

Remaining refinement: the [S] layer is name-based (top-level declarations), not
per-occurrence — it cannot yet distinguish a param from a local from a field, or
a local that shadows a global. That needs the resolver to record per-occurrence
resolutions (a larger change).
