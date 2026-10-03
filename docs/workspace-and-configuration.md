# Workspace, project, and configuration behavior

This document is the user-facing contract for workspace roots, source
ownership, URI schemes, compiler include paths, and settings. It deliberately
separates the behavior that the current standalone server implements from the
project resolver that W01/W02 will add later. A workspace root tells the
server where a document belongs for bookkeeping; it does not currently cause
files to be discovered, loaded, or semantically analyzed.

## What the server discovers today

The server does not search the filesystem for a project file, source files,
include directories, modules, or dependencies. It only learns workspace
roots from `initialize`:

1. A non-empty `workspaceFolders` array is preferred. Folder entries are
   validated before initialization changes state, and the accepted URI values
   are stored in client order after URI canonicalization.
2. When `workspaceFolders` is absent, `null`, or empty, a valid non-empty
   `rootUri` is used as the one legacy root.
3. If neither field supplies a root, the session is standalone. A document
   outside every supplied root is also treated as standalone and remains
   usable as an open overlay.

There can be at most 32 workspace folders. Folder names are required by the
LSP shape and are validated, but the current server does not use those names
for resolution. A private `$/elisa/workspace` request can inspect the
canonical roots and the selected root index for a URI; this is diagnostic
bookkeeping, not a public project-resolution API.

Root ownership is deterministic. The server compares canonical URI strings,
requires a path boundary after a matching root (unless the root already ends
in `/`), and chooses the longest matching root. Thus
`file:///work/app/nested/main.elisa` belongs to a nested root while
`file:///work/app-other/main.elisa` does not belong to `file:///work/app`.
Changing workspace folders is not dynamically advertised; restart the LSP
session after changing the folder set.

The current scope intentionally excludes:

- reading `project.json` or any user project configuration;
- discovering `include`/module files from disk;
- resolving imports, dependencies, or project-wide symbols;
- file watching, external-change invalidation, and workspace diagnostics; and
- separate semantic contexts for overlapping or differently targeted roots.

These are W01/W02/W03/W04 responsibilities. Until those features land, a
root match must not be interpreted as evidence that a dependency is available
or that a workspace-wide query is complete.

## Include paths and compiler inputs

There are two different kinds of include path:

| Setting | Owner | Effect |
| --- | --- | --- |
| `project.json` `include-dirs` (`["src"]`) | This repository's build | Describes the server source include base. It is part of the checked-in build configuration; it is not a client project setting. |
| `ELISA_COMPILER_ROOT` | `build.sh` | Selects the Elisa compiler checkout whose semantic frontend and standard-library source are staged into the build. The default is the adjacent `../Elisa-compiler` checkout. |
| User project include/module paths | Future W02 resolver | No current effect. The standalone server does not pass client workspace settings to a filesystem-backed compiler loader. |

The frontend include used by the server is the staged compiler source at
`Elisa-compiler/src/semantic/semantic.elisa`. `ELISA_COMPILER_ROOT` therefore
selects a compiler **source** checkout for building the server; it does not
select a backend executable and it does not configure include paths for an
editor's Elisa project. Build provenance records the selected checkout and
the exact source fingerprint in `build/manifest.json`.

For a future project resolver, include paths must be derived from the
compiler's own configuration and search order. The resolver must use the
open-document overlay first, keep source identity separate from display
paths, bound traversal and file size, and report missing or cyclic includes
as structured analysis conditions. A client setting or arbitrary build
script must never cause the LSP to execute shell code.

## Unsaved-buffer ownership

An open document is the authoritative source for every operation that the
current server supports. The lifecycle is:

| Event | Current behavior |
| --- | --- |
| `textDocument/didOpen` | Validates URI, language ID, version, and text, then stores the exact UTF-8 bytes before starting semantic analysis. |
| `textDocument/didChange` | Applies full or incremental changes in order against a temporary snapshot. The whole batch commits only after every entry validates. Stale/equal versions and invalid ranges are ignored without mutation. |
| `textDocument/didSave` | Ignored. Optional save text never replaces the overlay and does not trigger analysis. The server advertises no save capability. |
| `textDocument/willSave` / `willSaveWaitUntil` | Ignored and never used to write or reload a file. |
| `textDocument/didClose` | Removes the open overlay, clears open-file diagnostics, and releases the current source and derived caches. |
| Duplicate `didOpen` | Replaces the old source as a new document lifetime and advances the internal generation, even when the client repeats the version. |

The server does not read a closed file from disk to answer a provider
request. Unknown or closed URIs return the documented empty/null provider
results. A semantic analysis failure leaves the accepted source available to
source-only providers, marks semantic caches failed, and clears stale
diagnostics; it never rolls the document back to older text.

This overlay rule currently applies per open URI. It does not extend to
unopened dependencies because dependency loading is not implemented. When
W02 adds a virtual file system, an open buffer must shadow the corresponding
disk file by canonical identity, and the graph must be invalidated when that
overlay changes or closes.

## Configuration precedence

The process and protocol settings have separate ownership and validation:

1. Hard transport, document, cache, and output limits come from their
   `ELISA_LSP_*` environment variables. They are parsed before the server
   reads a frame; invalid values terminate startup with status 2. Clients
   cannot raise these limits through JSON-RPC.
2. `ELISA_LSP_ANALYSIS_TIMEOUT_MS` supplies the process default for one
   analysis worker deadline (30,000 ms by default, bounded to 100–300,000 ms).
3. A valid `initialize.params.initializationOptions.elisa.analysisTimeoutMs`
   overrides that environment default for the session. The recognized value
   must be an LSP signed integer in the documented range.
4. A valid
   `workspace/didChangeConfiguration.params.settings.elisa.analysisTimeoutMs`
   replaces the current session value at a message boundary. Invalid or
   out-of-range recognized values are ignored atomically, preserving the last
   accepted value.
5. Unknown top-level settings, unknown members inside the `elisa` namespace,
   and options owned by another extension are ignored. The server does not
   issue `workspace/configuration` requests, so there is no client-response
   layer that can supersede the values above.

Workspace folders and `rootUri` are routing metadata, not a configuration
source. They do not override environment limits, select a compiler, or cause
project files to be read. The authoritative names, bounds, and tests for the
current settings are in `docs/feature-manifest.json` and
`test/configuration_test.sh`.

## URI schemes and filesystem paths

Document identity is lexical and independent of filesystem state:

| URI form | Accepted as an open overlay | Filesystem behavior |
| --- | --- | --- |
| `file:` | Yes. Scheme and file authority receive the documented canonicalization; the incoming spelling is retained for responses. | No filesystem access occurs today. `Uri::file_uri_to_path` is an explicit, pure conversion boundary for a future file-backed feature. |
| `untitled:` | Yes. It remains an in-memory identity. | It has no disk path and is never fetched. |
| Other non-empty schemes (for example `https:`) | Yes as opaque in-memory identities, preserving the current no-fetch behavior. | No network or filesystem access occurs. A future provider must reject or explicitly handle a remote resource rather than fetch it implicitly. |
| Scheme-less or otherwise opaque non-empty URI strings | Retained as session identities for compatibility; clients should still send RFC-compliant document URIs. | No path conversion is attempted. |

`Uri::canonical_key` lowercases schemes, lowercases and removes
`localhost` from `file` authorities, decodes non-reserved percent escapes,
retains reserved escapes such as `%2F`, preserves the query, and omits the
fragment. Malformed percent escapes remain literal for compatibility. The
response URI uses the client's original spelling, while lookup and root
membership use the canonical key.

Only `Uri::file_uri_to_path` may cross from a file URI to an operating-system
path. It strictly rejects malformed escapes, NUL, URI query/fragment
metadata, relative paths, and unsupported POSIX remote authorities. POSIX
and Windows path grammars are selected explicitly; the conversion does not
normalize dot segments, fold case, resolve symlinks, check existence, or
change URI lookup identity. The shipped server itself currently has POSIX
transport/process support only, and this pure conversion does not claim
Windows server support.

The distinction matters for aliases: lexical URI identity deliberately does
not consult case sensitivity, inode identity, symlink targets, or mount
points. `test/filesystem_identity_test.sh` measures case behavior and symlink
identity in a private temporary directory on the validation host; it never
mutates a project and never turns that observation into an overlay alias. The
measurement is per filesystem/volume. The resolver must not infer case
behavior from `Darwin`, `Linux`, or `Windows` alone, because one host can mount
both case-sensitive and case-insensitive volumes.

The future W02 resolver has this explicit alias policy:

* The open-document/protocol key remains the canonical lexical URI and the
  client's original spelling remains the response URI. A case variant or a
  symlink spelling never replaces, merges, or edits that overlay by itself.
* For an existing file, the resolver may attach a separate physical identity
  only after a filesystem query succeeds. It records the observed case policy
  (`sensitive`, `insensitive`, or `unknown`) for the containing volume and a
  file identity from `realpath`/file identity APIs. Missing files, permission
  errors, unsupported APIs, and symlink loops produce `unknown` and keep
  lexical entries distinct.
* A case-insensitive result permits physical aliasing for read/index graph
  deduplication only when the file identity agrees. A case-sensitive result
  preserves case-distinct paths. An unknown result fails closed. A symlink may
  share a physical identity for read/index purposes after successful target
  resolution, but the lexical URI and edit target stay separate; cycles and
  depth-limit failures are never followed.

This keeps source lookup, edits, diagnostics, and client-visible URIs stable
while allowing a later project resolver to deduplicate proven physical files.

## Verification and future expansion

The current contract is covered by independent regressions:

- `test/workspace_roots_test.sh` checks folder precedence, nested longest-root
  ownership, trailing slashes, path boundaries, and `rootUri` fallback.
- `test/configuration_test.sh` checks environment/default handling through
  stats, initialize overrides, notification updates, malformed values, and
  duplicate-key atomicity.
- `test/documents_test.sh` and `test/incremental_sync_test.sh` check overlay
  ownership, duplicate opens, save no-ops, stale versions, and transactional
  edits.
- `test/uri_test.sh` and `test/uri_path_test.sh` check canonical identity,
  opaque schemes, reserved escapes, strict file-path conversion, and the
  explicit POSIX/Windows path grammars.
- `test/filesystem_identity_test.sh` measures the validation host's
  case-sensitivity and symlink behavior in a private temporary directory and
  records the fail-closed alias policy. It does not change the current
  lexical overlay behavior.

When project discovery is implemented, add a separate resolver contract and
tests before changing any of these rules. In particular, do not silently turn
an existing root-bookkeeping success into a claim that a cross-file analysis
or include lookup succeeded.
