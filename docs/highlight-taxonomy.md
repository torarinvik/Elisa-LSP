# Elisa semantic highlighting — token taxonomy

The color space mirrors the semantic space: **hue = family, hue-offset =
subfamily, lightness/saturation = leaf**. Two tokens look as similar as they
*are* — `i64` sits nearly on top of `u32`, both sit near `f64`, and all of
them sit far from `can Memory.Allocate`. Colors will be assigned in OKLCH so
equal semantic distance reads as equal perceptual distance.

Classification source: **[L]** = lexical (knowable from the token stream —
instant, client-side or TextMate layer) · **[S]** = semantic (needs the
frontend's symbol table — served as LSP semantic tokens).

## 1. Types (cool blue → cyan arc)
The type family is the biggest cluster; numerics huddle tightest.
- **1a. Signed integrals** [L]: `int` `i8` `i16` `i32` `i64` `isize`
- **1b. Unsigned integrals** [L]: `u8` `u16` `u32` `u64` `usize` `uintptr`
  — a hair from 1a; integrals are near-identical shades
- **1c. Floats** [L]: `f32` `f64` — one step further from the integrals
- **1d. Tiny scalars** [L]: `bool` `char` — numeric-adjacent, distinct step
- **1e. Strings/views** [L]: `cstr` `dstr` `sview` — cyan end of the arc
- **1f. Containers** [L]: `darray` `dict` `set` `view`, fixed arrays `T[N]`
- **1g. User types** [S]: struct names, enum names, protocol names, type
  aliases, generic params (`T`, `@r`) — same arc, lighter; the *kind*
  (struct vs enum vs protocol) is a small offset, def-site slightly bolder
  than use-site
- **1h. `void`** [L]: desaturated — the absence-of-type type

## 2. Literals & value atoms (warm amber arc)
- **2a. Integer literals** [L] (dec/hex) · **2b. Float literals** [L] —
  adjacent shades, mirroring 1a↔1c
- **2c. Char literals** [L] · **2d. String literals** [L] — string escapes a
  brighter accent within 2d
- **2e. Value keywords** [L]: `true` `false` `null` `zeroed` — bool literals
  match 1d's hue-relationship; `null`/`zeroed` desaturated like `void`

## 3. Functions (gold)
- **3a. Definition name** [S]: name in `def f(...)` — boldest gold
- **3b. Call/use** [S]: `f(x)` — same hue, lighter (def↔use = weight, not hue)
- **3c. UFCS/method position** [S]: `recv.f(x)` — tiny offset from 3b
- **3d. Lambda heads** [L]: `fn` `λ` (+ math-alphanumeric lambdas) — the
  anonymous corner of the family
- **3e. Extern/exported** [S]: `extern`/`export fn` names — gold with a
  boundary tint (they cross the FFI edge)

## 4. Bindings (green-teal)
- **4a. Parameters** [S] · **4b. Locals** [S] — adjacent
- **4c. Loop/pattern/refinement bindings** [S]: `for x`, match-arm binds,
  `if e is m` — same shade as locals, italic
- **4d. Fields** [S]: `obj.field` selectors
- **4e. Globals & consts** [S]: `global`/`const` names — deeper, weightier
- **4f. Mutability** [modifier, S]: a `mutable` binding renders brighter/
  underlined wherever it appears — mutability is a *modifier dimension*,
  not a new color
- **4g. The discard `_`** [L]: near-invisible grey

## 5. Effects & permissions (violet — the loud family, per design)
- **5a. Grant syntax** [L]: `can`, `uses`
- **5b. Permission names** [S]: `Memory.Allocate`, `Abort.Panic`,
  `Console.Format`, effect aliases — saturated violet
- **5c. Unsafe family** [S]: `Unsafe.*`, `trusted` — violet shifted toward
  red: same family, visibly hotter (danger gradient *within* the family)
- **5d. Error sets** [L/S]: `error` decls, `raises`, error-type names —
  violet↔red midpoint (they're the "throwing" corner of effects)

## 6. Memory & regions (earthy orange/copper)
- **6a. Region keywords** [L]: `region` `destroy` `in <owner>:` `new[r]`
- **6b. Region/storage qualifiers** [L]: `heap` `stack` `tail` `static`,
  `@region` annotations, `perm`
- **6c. Type-shape operators** [L]: `&` `?` postfixes, `move` — quiet copper
  accents on the type they modify

## 7. Control flow (rose/red)
- **7a. Branching/looping** [L]: `if` `elif` `else` `while` `for` `match`
  `break` `continue` `return` `pass` `defer` `guard` `do`
- **7b. Error control** [L]: `try` `catch` `raise` `panic` `get`/`else` —
  rose shifted toward 5d (error sets), linking the two ends
- **7c. Concurrency** [L]: `parallel` `nursery` `pool` `submit` `await`
  `wait` `lock` — rose shifted toward violet (behavioral cousins of effects)

## 8. Declaration skeleton (steel — strong but neutral)
[L]: `def` `struct` `enum` `module` `extend` `impl` `protocol` `const`
`global` `type` `alias` `law` `permission` `effect` `using` `include`
`export` `extern` `public` `private` `packed` `layout` `repr` `of`,
inheritance `is`, `linear`/`affine` affinity markers.
These are the scaffolding — one calm hue so the *contents* carry the color.

## 9. Verification & contracts (proof green)
- **9a. Contract clauses** [L]: `requires` `ensure(s)` `invariant`
  `decreases` `changes` `preserves` `fulfills`
- **9b. Quantifiers/refinements** [L]: `forall` `exists` `where`, `is`
  refinement tests
- **9c. Ghost world** [L]: `ghost` `lemma` `@property` — desaturated green
  (present in source, absent at runtime)

## 10. Operators & punctuation (greys, three exceptions)
- Default: low-salience grey for `. , ( ) [ ] { } : :: ->` etc.
- **Exceptions that earn color**: `<-` (mutation — echoes the 4f mutability
  accent), `=>` (lambda body — echoes 3d), range operators `..< ..= ..>`
  (echo 2a, they construct values)

## 11. Meta & annotations (muted)
- **11a. Comments** [L]: classic muted grey-green
- **11b. Decorators** [L]: `@hot` `@inline` `@test` `@align` … — muted
  mustard
- **11c. Compile-time directives** [L]: `static if/elif/else/generate/
  assert`, `emit`, `${...}` splices — preprocessor lavender-grey
- **11d. Modules/namespaces** [S]: `Ast::` qualifiers — quiet steel-blue

## Cross-cutting modifier dimensions (not colors)
- **definition vs use**: weight/brightness (bold at def site)
- **mutable**: brightness/underline overlay (4f)
- **unsafe/trusted context**: red-shift overlay (5c)
- **ghost/spec-only**: desaturation overlay (9c)
- **deprecated** (future): strikethrough

## Implementation phases
1. **Lexical layer** — everything [L]: a TextMate grammar (or LSP4IJ
   `semanticTokens` full-file from the lexer) gives instant color.
2. **Semantic layer** — everything [S]: LSP `textDocument/semanticTokens`
   served by elisa-lsp from the frontend's real symbol table — the same
   single source of truth as diagnostics. Semantic tokens override lexical
   ones where both apply.
