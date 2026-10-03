# Normalize the compiler source root once before test children create temporary
# Elisa sources whose include paths resolve relative to those temporary files.
normalize_elisa_compiler_root() {
  local default_lsp_root="$1"
  local compiler_root="${ELISA_COMPILER_ROOT:-$default_lsp_root/../Elisa-compiler}"
  local resolved_root

  if [[ -d "$compiler_root" ]]; then
    if ! resolved_root="$(cd -- "$compiler_root" && pwd -P)"; then
      echo "error: cannot resolve Elisa compiler root: $compiler_root" >&2
      return 1
    fi
    compiler_root="$resolved_root"
  fi

  ELISA_COMPILER_ROOT="$compiler_root"
  export ELISA_COMPILER_ROOT
}
