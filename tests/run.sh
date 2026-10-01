#!/usr/bin/env bash
# shellcheck disable=SC1090  # the CLI under test is sourced from a dynamic path
set -uo pipefail

# Deterministic terminal: results must not depend on the caller's TERM.
export TERM=dumb
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/script/renombrador.sh"
ORIGINAL_ROOT="${ORIGINAL_ROOT:-}"
TMP=$(mktemp -d)
PASS=0
FAILS=0
SKIPS=0
TOTAL=0
trap 'rm -rf "$TMP"' EXIT

new_case() {
  CASE_DIR=$(mktemp -d "$TMP/case.XXXXXX")
  CASE_HOME=$(mktemp -d "$TMP/home.XXXXXX")
  export CASE_DIR CASE_HOME
}

pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAILS=$((FAILS + 1)); }
skip() { printf 'SKIP  %s\n' "$1"; return 77; }

run_test() {
  local name="$1" rc
  shift
  TOTAL=$((TOTAL + 1))
  if (set -uEo pipefail; "$@"); then
    pass "$name"
  else
    rc=$?
    if (( rc == 77 )); then
      SKIPS=$((SKIPS + 1))
    else
      fail "$name"
    fi
  fi
}

assert_file() { [[ -e "$1" || -L "$1" ]]; }
assert_absent() { [[ ! -e "$1" && ! -L "$1" ]]; }
assert_content() { printf '%s' "$2" | cmp -s - "$1"; }
assert_contains() { [[ "$1" == *"$2"* ]]; }
no_raw_control() { [[ "$1" != *$'\e'* && "$1" != *$'\xc2\x9b'* ]]; }

run_cli() {
  local lang="$1"
  shift
  HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG="$lang" bash "$SCRIPT" "$@"
}

capture_cli() {
  local lang="$1" out
  shift
  out=$(mktemp "$TMP/cli.XXXXXX") || { CLI_OUTPUT=''; CLI_RC=1; return; }
  if run_cli "$lang" "$@" >"$out" 2>&1; then
    CLI_RC=0
  else
    CLI_RC=$?
  fi
  CLI_OUTPUT=$(cat -- "$out")
  rm -f -- "$out"
}

# A harmless CLI run that does need the config dir (--help/--version do not).
cli_dry_run() {
  printf a > "$CASE_DIR/a.txt"
  run_cli en --archivo "$CASE_DIR/a.txt" --metodo prefijo --prefijo X_ --dry-run
}

project_integrity_test() {
  new_case
  bash -n "$SCRIPT" || return 1
  bash -n "$ROOT_DIR/tests/run.sh" || return 1
  [[ -x "$ROOT_DIR/tests/run.sh" ]] || return 1
  [[ -x "$ROOT_DIR/tests/lint.sh" ]] || return 1
  [[ "$(stat -c '%a' "$SCRIPT")" == "644" ]] || return 1
  [[ -f "$ROOT_DIR/assets/icons/renombrador.png" ]] || return 1
  [[ "$(stat -c '%a' "$ROOT_DIR/tests/run.sh")" == "755" ]] || return 1
  [[ -f "$ROOT_DIR/README.md" && -f "$ROOT_DIR/README.es.md" && -f "$ROOT_DIR/LICENSE.txt" ]] || return 1
  [[ -f "$ROOT_DIR/.github/workflows/quality.yml" && ! -e "$ROOT_DIR/tests/quality.yml" ]] || return 1
  while IFS= read -r rel; do [[ -f "$ROOT_DIR/$rel" ]] || return 1; done \
    < <(grep -oE '\.github/workflows/[A-Za-z0-9._-]+' "$ROOT_DIR/.github/CONTRIBUTING.md")
  python3 - "$ROOT_DIR/assets/icons/renombrador.png" <<'PY' || return 1
import struct
import sys
from pathlib import Path
data = Path(sys.argv[1]).read_bytes()
assert data[:8] == b"\x89PNG\r\n\x1a\n"
length, chunk = struct.unpack(">I4s", data[8:16])
assert chunk == b"IHDR" and length == 13
w, h, bit_depth, color_type = struct.unpack(">IIBB", data[16:26])
assert (w, h, bit_depth, color_type) == (512, 512, 8, 6)
PY
  [[ ! -e "$ROOT_DIR/script/renombrador.sh.original" && ! -e "$ROOT_DIR/script/renombrador.sh.bak" ]] || return 1
  if [[ -n "$ORIGINAL_ROOT" && -d "$ORIGINAL_ROOT" ]]; then
    while IFS= read -r rel; do
      now="$rel"; [[ "$rel" != tests/quality.yml ]] || now=.github/workflows/quality.yml
      [[ -e "$ROOT_DIR/$now" || -L "$ROOT_DIR/$now" ]] || return 1
      case "$rel" in
        README.md|README.es.md|script/renombrador.sh|tests/run.sh) ;;
        .github/SECURITY.md|.github/CONTRIBUTING.md|.github/PULL_REQUEST_TEMPLATE.md) ;;
        .github/ISSUE_TEMPLATE/bug_report.md|.github/ISSUE_TEMPLATE/custom.md|.github/ISSUE_TEMPLATE/feature_request.md) ;;
        .github/CODE_OF_CONDUCT.md|assets/templates/example-templates.en.conf|assets/templates/plantillas-ejemplo.es.conf) ;;
        *) cmp -s "$ORIGINAL_ROOT/$rel" "$ROOT_DIR/$now" || return 1
           [[ "$(stat -c '%a' "$ORIGINAL_ROOT/$rel")" == "$(stat -c '%a' "$ROOT_DIR/$now")" ]] || return 1 ;;
      esac
    done < <(cd "$ORIGINAL_ROOT" && find . -type f -printf '%P\n' | sort)
  fi
}

readme_integrity_test() {
  new_case
  ROOT="$ROOT_DIR" ORIGINAL="$ORIGINAL_ROOT" python3 - <<'PY'
from pathlib import Path
import os, re, unicodedata
from urllib.parse import unquote

root = Path(os.environ['ROOT'])
original = Path(os.environ['ORIGINAL']) if os.environ.get('ORIGINAL') else None

for name, back in [('README.md', '[Español](README.es.md)'),
                   ('README.es.md', '[English](README.md)')]:
    text = (root / name).read_text(encoding='utf-8')
    assert back in text, (name, 'language link')
    assert '[LICENSE.txt](LICENSE.txt)' in text
    assert '[LICENSE](LICENSE)' not in text
    assert './tests/run.sh' in text

    links = re.findall(r'(?<!!)\[[^\]]*\]\(([^)]+)\)', text)
    for target in links:
        target = target.strip().split()[0]
        if target.startswith('#') or re.match(r'^(?:https?|mailto):', target):
            continue
        path = unquote(target.split('#', 1)[0])
        assert path and (root / path).resolve().exists(), (name, target)

    headings = []
    for line in text.splitlines():
        m = re.match(r'^#{1,6}\s+(.+?)\s*#*$', line)
        if not m:
            continue
        h = m.group(1).strip().lower()
        h = unicodedata.normalize('NFC', h)
        h = re.sub(r'[^\w\s-]', '', h, flags=re.UNICODE)
        h = re.sub(r'\s+', '-', h)
        h = re.sub(r'-+', '-', h).strip('-')
        headings.append(h)
        headings.append(unicodedata.normalize('NFKD', h).encode('ascii', 'ignore').decode())
    slugs = set(headings)
    for target in re.findall(r'(?<!!)\[[^\]]*\]\((#[^)]+)\)', text):
        slug = unicodedata.normalize('NFC', target[1:])
        assert slug in slugs or unicodedata.normalize('NFKD', slug).encode('ascii', 'ignore').decode() in slugs, (name, target)

    for src in re.findall(r'\bsrc=["\']([^"\']+)', text, re.I):
        if src.startswith(('http://', 'https://')):
            continue
        assert (root / unquote(src)).resolve().exists(), (name, src)

    assert len(re.findall(r'^```', text, re.M)) % 2 == 0

# Main menu, custom templates and Nemo now come from assets/screenshots/1-3.
gone = ('19215211-322f-4595-b9cd-ec4048cd7d50', 'de8f4fb6-1814-4e70-ad20-109b166f97fb', '6a3a5101-48c3-4cc5-8252-6891c627cfdd')
for name in ('README.md', 'README.es.md'):
    if original and (original / name).is_file():
        gh = r'https://github\.com/user-attachments/assets/[^"\s)]+'
        want = {u for u in re.findall(gh, (original / name).read_text(encoding='utf-8')) if not u.endswith(gone)}
        cur = set(re.findall(gh, (root / name).read_text(encoding='utf-8')))
        assert cur == want, (name, sorted(want - cur), sorted(cur - want))
PY
}

translation_contract_test() {
  new_case
  ROOT="$ROOT_DIR" python3 - <<'PY'
from pathlib import Path
import os, re

path = Path(os.environ['ROOT']) / 'script' / 'renombrador.sh'
src = path.read_text(encoding='utf-8')
arrays = {}
for name in ('TXT_ES', 'TXT_EN'):
    block = src.split(f'declare -A {name}=(', 1)[1].split('\n)\n', 1)[0]
    arrays[name] = dict(re.findall(r'^\s*\[([^]]+)\]="(.*)"$', block, re.M))

es, en = arrays['TXT_ES'], arrays['TXT_EN']
assert set(es) == set(en)
assert all(en[k] for k in en)
assert all(not re.search(r'[áéíóúñÁÉÍÓÚÑ]', v) for v in en.values())
for key in es:
    assert sorted(re.findall(r'%[0-9]*[a-zA-Z]', es[key])) == sorted(re.findall(r'%[0-9]*[a-zA-Z]', en[key])), key
assert 'starting number' in en['numbering_start_hint']
assert '(2, 3, 4' not in en['numbering_start_hint']
assert es['template_default_name'] == 'Plantilla_%s' and en['template_default_name'] == 'Template_%s'
assert es['export_default'] == 'plantillas_renombrador.txt' and en['export_default'] == 'templates_renombrador.txt'
assert es['switch_to_es'] == 'Cambiar a español' and es['language_changed'] == 'Idioma cambiado a español.'
PY
}


pure_helpers_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  [[ "$(normalizar_ruta file.txt)" == "./file.txt" ]] || return 1
  [[ "$(normalizar_ruta dir/file.txt)" == "dir/file.txt" ]] || return 1

  separar_nombre_ext '.bashrc'
  [[ "$SEPARAR_BASE" == '.bashrc' && -z "$SEPARAR_EXT" ]] || return 1
  separar_nombre_ext 'photo.tar.gz'
  [[ "$SEPARAR_BASE" == 'photo.tar' && "$SEPARAR_EXT" == 'gz' ]] || return 1
  separar_nombre_ext 'README'
  [[ "$SEPARAR_BASE" == 'README' && -z "$SEPARAR_EXT" ]] || return 1

  [[ "$(detectar_tipo jpg)" == Foto ]] || return 1
  [[ "$(detectar_tipo MP4)" == Video ]] || return 1
  [[ "$(detectar_tipo PDF)" == Documento ]] || return 1
  [[ "$(detectar_tipo sh)" == Codigo ]] || return 1
  [[ "$(detectar_tipo unknown)" == Archivo ]] || return 1

  [[ "$(capitalizar 'mi_foto FINAL.jpg')" == 'Mi_Foto Final.jpg' ]] || return 1
  [[ "$(sanear_nuevo '  a/b  ')" == 'a-b' ]] || return 1
  [[ "$(sanear_nuevo '.')" == sin_nombre_* ]] || return 1
  [[ "$(delimitador_para 'a/b' 'c#d')" == '|' ]] || return 1
  [[ -n "$(validar_regex '([a-' 'x' '/')" ]] || return 1

  [[ "$(normalizar_sn s)" == s && "$(normalizar_sn S)" == s ]] || return 1
  [[ "$(normalizar_sn y)" == s && "$(normalizar_sn Y)" == s ]] || return 1
  [[ "$(normalizar_sn n)" == n && "$(normalizar_sn '')" == n && "$(normalizar_sn x)" == n ]] || return 1
  local ans
  for ans in si Si SI sí Sí SÍ yes Yes YES; do [[ "$(normalizar_sn "$ans")" == s ]] || return 1; done
  for ans in no NO nope sii sip yess ye 'sí señor'; do [[ "$(normalizar_sn "$ans")" == n ]] || return 1; done
  # ${r,,} does not lowercase "Í" outside UTF-8 locales.
  [[ "$(LC_ALL=C; normalizar_sn SÍ)" == s && "$(LC_ALL=C; normalizar_sn Sí)" == s ]] || return 1

  [[ "$(t template_default_name 120000)" == 'Template_120000' ]] || return 1

  [[ "$(normalizar_decimal 010)" == 10 ]] || return 1
  [[ "$(normalizar_decimal 000)" == 0 ]] || return 1
  [[ "$(normalizar_decimal 7)" == 7 ]] || return 1
  en_rango_decimal 9000000000000000000 9000000000000000000 || return 1
  en_rango_decimal 8999999999999999999 9000000000000000000 || return 1
  en_rango_decimal 9000000000000000001 9000000000000000000 && return 1
  en_rango_decimal 99999999999999999999999999999999999999 9000000000000000000 && return 1
  en_rango_decimal 18 18 || return 1
  en_rango_decimal 19 18 && return 1
  return 0
}

pure_text_transformations_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  FILES=("$CASE_DIR/One Test.TXT" "$CASE_DIR/Two.TXT")
  NOMBRES_COLA=('One Test.TXT' 'Two.TXT')

  transformar_prefijo 'P_'
  [[ "${NOMBRES_COLA[0]}" == 'P_One Test.TXT' && "${NOMBRES_COLA[1]}" == 'P_Two.TXT' ]] || return 1
  transformar_sufijo '_S'
  [[ "${NOMBRES_COLA[0]}" == 'P_One Test_S.TXT' && "${NOMBRES_COLA[1]}" == 'P_Two_S.TXT' ]] || return 1

  transformar_buscar_reemplazar 1 'P_' 'R_'
  [[ "${NOMBRES_COLA[0]}" == 'R_One Test_S.TXT' ]] || return 1
  transformar_buscar_reemplazar 2 '(_S)\.TXT$' '_DONE.txt'
  [[ "${NOMBRES_COLA[0]}" == 'R_One Test_DONE.txt' ]] || return 1

  transformar_mayus_minus 1
  [[ "${NOMBRES_COLA[0]}" == 'r_one test_done.txt' ]] || return 1
  NOMBRES_COLA=('hola-mundo.txt' 'dos palabras.txt')
  transformar_mayus_minus 2
  [[ "${NOMBRES_COLA[0]}" == 'HOLA-MUNDO.TXT' ]] || return 1
  NOMBRES_COLA=('hola-mundo.TXT' 'dos palabras.txt')
  transformar_mayus_minus 3
  [[ "${NOMBRES_COLA[0]}" == 'Hola-Mundo.TXT' && "${NOMBRES_COLA[1]}" == 'Dos Palabras.txt' ]] || return 1
  NOMBRES_COLA=('hola-mundo.TXT' 'dos palabras.txt')
  transformar_mayus_minus 4
  [[ "${NOMBRES_COLA[0]}" == 'Hola-mundo.TXT' && "${NOMBRES_COLA[1]}" == 'Dos palabras.txt' ]] || return 1

  NOMBRES_COLA=('name with  spaces?.txt' 'other/file*.txt')
  transformar_limpiar '_'
  [[ "${NOMBRES_COLA[0]}" == 'name_with__spaces.txt' ]] || return 1
  [[ "${NOMBRES_COLA[1]}" == 'other_file.txt' ]] || return 1
}

pure_numbering_and_pattern_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  printf x > "$CASE_DIR/b.txt"
  printf xx > "$CASE_DIR/a.txt"
  printf xxx > "$CASE_DIR/c.txt"
  FILES=("$CASE_DIR/b.txt" "$CASE_DIR/a.txt" "$CASE_DIR/c.txt")
  NOMBRES_COLA=('b.txt' 'a.txt' 'c.txt')
  mapfile -t order < <(orden_indices_por_criterio tamano)
  [[ "${order[*]}" == '0 1 2' ]] || return 1

  transformar_numeracion 1 'file' 7 2 '2 0 1'
  [[ "${NOMBRES_COLA[0]}" == 'file_08.txt' ]] || return 1
  [[ "${NOMBRES_COLA[1]}" == 'file_09.txt' ]] || return 1
  [[ "${NOMBRES_COLA[2]}" == 'file_07.txt' ]] || return 1

  NOMBRES_COLA=('b.txt' 'a.txt' 'c.txt')
  transformar_numeracion 2 '' 1 1 '0 1 2'
  [[ "${NOMBRES_COLA[0]}" == 'b_1.txt' && "${NOMBRES_COLA[1]}" == 'a_2.txt' && "${NOMBRES_COLA[2]}" == 'c_3.txt' ]] || return 1

  NOMBRES_COLA=('photo.jpg' 'notes.txt')
  FILES=("$CASE_DIR/b.txt" "$CASE_DIR/a.txt")
  aplicar_patron '{n}_{name}.{ext}' 3 2
  [[ "${NOMBRES_COLA[0]}" == '03_photo.jpg' && "${NOMBRES_COLA[1]}" == '04_notes.txt' ]] || return 1

  NOMBRES_COLA=('photo.jpg' 'notes.txt')
  aplicar_patron '{n}_{name}.{ext}' 3 0
  [[ "${NOMBRES_COLA[0]}" == '3_photo.jpg' && "${NOMBRES_COLA[1]}" == '4_notes.txt' ]] || return 1
}

atomic_file_write_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  local target="$CASE_DIR/state.txt" rc
  printf 'old' > "$target"
  chmod 640 "$target"
  printf 'new' | escritura_atomica "$target" || return 1
  assert_content "$target" 'new' || return 1
  [[ "$(stat -c '%a' "$target")" == 640 ]] || return 1

  mkdir -p "$CASE_DIR/bin"
  cat > "$CASE_DIR/bin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "${@: -1}" == "$CASE_DIR/state.txt" ]]; then exit 1; fi
exec /usr/bin/mv "$@"
EOF
  chmod +x "$CASE_DIR/bin/mv"
  export CASE_DIR
  set +e
  printf 'broken' | PATH="$CASE_DIR/bin:$PATH" escritura_atomica "$target"
  rc=$?
  set -e
  (( rc != 0 )) || return 1
  assert_content "$target" 'new' || return 1
  [[ -z "$(find "$CASE_DIR" -maxdepth 1 -name '.state.txt.tmp.*' -print -quit)" ]] || return 1
}


atomic_write_long_name_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  local nombre_largo target src
  nombre_largo=$(printf 'a%.0s' $(seq 1 250)); nombre_largo+=".txt"
  target="$CASE_DIR/$nombre_largo"

  # A destination name this close to the 255-byte filename limit used to
  # make mktemp fail ("File name too long") even though the name itself
  # is valid, because the temp pattern embedded it in full.
  printf 'contenido' | escritura_atomica "$target" || return 1
  assert_content "$target" 'contenido' || return 1
  [[ -z "$(find "$CASE_DIR" -maxdepth 1 -name '.*' -print -quit)" ]] || return 1

  src="$CASE_DIR/source.txt"
  printf 'origen' > "$src"
  rm -f "$target"
  copia_atomica "$src" "$target" || return 1
  assert_content "$target" 'origen' || return 1
  [[ -z "$(find "$CASE_DIR" -maxdepth 1 -name '.*' -print -quit)" ]] || return 1
}


atomic_persistence_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  local target="$CASE_DIR/state.txt" sync_log="$CASE_DIR/sync.log" rc
  printf 'old' > "$target"

  mkdir -p "$CASE_DIR/bin"
  cat > "$CASE_DIR/bin/sync" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYNC_LOG"
exit 0
EOF
  chmod +x "$CASE_DIR/bin/sync"
  export SYNC_LOG="$sync_log" PATH="$CASE_DIR/bin:$PATH"

  printf 'new' | escritura_atomica "$target" || return 1
  assert_content "$target" 'new' || return 1
  (( $(wc -l < "$sync_log") >= 2 )) || return 1
  grep -q -- "$CASE_DIR/.state.txt.tmp." "$sync_log" || return 1
  grep -q -- "$CASE_DIR" "$sync_log" || return 1

  cat > "$CASE_DIR/bin/sync" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  set +e
  printf 'broken' | PATH="$CASE_DIR/bin:$PATH" escritura_atomica "$target"
  rc=$?
  set -e
  (( rc != 0 )) || return 1
  assert_content "$target" 'new' || return 1
  [[ -z "$(find "$CASE_DIR" -maxdepth 1 -name '.state.txt.tmp.*' -print -quit)" ]] || return 1
}


atomic_copy_persistence_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  local src="$CASE_DIR/source.txt" target="$CASE_DIR/target.txt" rc
  printf 'source' > "$src"
  printf 'old' > "$target"

  mkdir -p "$CASE_DIR/bin"
  cat > "$CASE_DIR/bin/sync" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$CASE_DIR/bin/sync"
  export PATH="$CASE_DIR/bin:$PATH"
  set +e
  PATH="$CASE_DIR/bin:$PATH" copia_atomica "$src" "$target"
  rc=$?
  set -e
  (( rc != 0 )) || return 1
  assert_content "$target" 'old' || return 1
  [[ -z "$(find "$CASE_DIR" -maxdepth 1 -name '.target.txt.tmp.*' -print -quit)" ]] || return 1

  rm -f "$CASE_DIR/bin/sync"
  copia_atomica "$src" "$target" || return 1
  assert_content "$target" 'source' || return 1

  mkdir "$CASE_DIR/dest-dir"
  printf 'child' > "$CASE_DIR/source-dir.txt"
  # Make a directory source to exercise recursive staging and synchronization.
  mkdir "$CASE_DIR/source-dir"
  printf 'child' > "$CASE_DIR/source-dir/child.txt"
  cat > "$CASE_DIR/bin/sync" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$CASE_DIR/bin/sync"
  set +e
  PATH="$CASE_DIR/bin:$PATH" copia_item_atomica "$CASE_DIR/source-dir" "$CASE_DIR/dest-dir/newdir"
  rc=$?
  set -e
  (( rc != 0 )) || return 1
  assert_absent "$CASE_DIR/dest-dir/newdir" || return 1
  [[ -z "$(find "$CASE_DIR/dest-dir" -maxdepth 1 -name '.renombrador_stage.*' -print -quit)" ]] || return 1
}


atomic_copy_subdir_fsync_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  local tree="$CASE_DIR/tree" sync_log="$CASE_DIR/sync.log"
  mkdir -p "$tree/sub1/sub2"
  printf 'child' > "$tree/sub1/sub2/file.txt"

  mkdir -p "$CASE_DIR/bin"
  cat > "$CASE_DIR/bin/sync" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYNC_LOG"
exit 0
EOF
  chmod +x "$CASE_DIR/bin/sync"
  export SYNC_LOG="$sync_log"

  # Every directory level of a copied tree must get its own fsync, not just
  # its root, or a crash right after the rename can lose subdirectory entries.
  PATH="$CASE_DIR/bin:$PATH" sincronizar_temporal "$tree" || return 1
  grep -qE "(^| )$tree/sub1/sub2( |$)" "$sync_log" || return 1
  grep -qE "(^| )$tree/sub1( |$)" "$sync_log" || return 1
  grep -qE "(^| )$tree( |$)" "$sync_log" || return 1
}


copy_symlink_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  printf 'target' > "$CASE_DIR/target.txt"
  ln -s "$CASE_DIR/target.txt" "$CASE_DIR/link.txt"
  mkdir "$CASE_DIR/out"
  copia_item_atomica "$CASE_DIR/link.txt" "$CASE_DIR/out/link.txt" || return 1
  [[ -L "$CASE_DIR/out/link.txt" ]] || return 1
  [[ "$(readlink -- "$CASE_DIR/out/link.txt")" == "$CASE_DIR/target.txt" ]] || return 1
}

# The embedded icon must be a well-formed 64x64 indexed PNG (all CRCs, palette, alpha, pixel data).
valid_icon_png() {
  python3 - "$1" <<'PY'
import struct
import sys
import zlib
from pathlib import Path

data = Path(sys.argv[1]).read_bytes()
assert data[:8] == b"\x89PNG\r\n\x1a\n"
pos, kinds, idat = 8, [], b""
while pos < len(data):
    length, kind = struct.unpack(">I4s", data[pos:pos + 8])
    body = data[pos + 8:pos + 8 + length]
    assert zlib.crc32(kind + body) == struct.unpack(">I", data[pos + 8 + length:pos + 12 + length])[0], kind
    kinds.append(kind)
    if kind == b"IHDR":
        assert struct.unpack(">IIBB", body[:10]) == (64, 64, 8, 3)
    elif kind == b"PLTE":
        assert len(body) // 3 > 16
    elif kind == b"IDAT":
        idat += body
    pos += 12 + length
assert kinds[0] == b"IHDR" and kinds[-1] == b"IEND" and b"tRNS" in kinds
assert len(zlib.decompress(idat)) == 64 * 65
PY
}

icon_installation_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  instalar_nemo >/dev/null || return 1
  # Nemo resolves Icon-Name through the icon theme: name in the action, file in hicolor.
  [[ "$APP_ICON" == "$HOME/.local/share/icons/hicolor/64x64/apps/renombrador.png" ]] || return 1
  [[ ! -L "$APP_ICON" ]] || return 1
  grep -Fqx 'Icon-Name=renombrador' "$NEMO_ACTION" || return 1
  ! grep -q '^Icon-Name=/' "$NEMO_ACTION" || return 1
  grep -Fqx 'Name=Rename with Renombrador...' "$NEMO_ACTION" || return 1
  valid_icon_png "$APP_ICON" || return 1
}

# The icon travels inside the script: a lone copy (no assets/ folder) installs it too.
icon_standalone_test() {
  new_case
  mkdir -p "$CASE_DIR/lone"
  cp "$SCRIPT" "$CASE_DIR/lone/renombrador.sh"
  HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en bash "$CASE_DIR/lone/renombrador.sh" --instalar-nemo >/dev/null 2>&1 || return 1
  grep -Fqx 'Icon-Name=renombrador' "$CASE_HOME/.local/share/nemo/actions/renombrador.nemo_action" || return 1
  valid_icon_png "$CASE_HOME/.local/share/icons/hicolor/64x64/apps/renombrador.png" || return 1
}

# A stale or corrupt icon is replaced on reinstall; the ones earlier versions kept in APP_DIR go away.
icon_reinstall_repairs_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  mkdir -p "${APP_ICON%/*}" "$APP_DIR"
  printf junk > "$APP_ICON"
  printf old > "$APP_DIR/renombrador.png"
  printf old > "$APP_DIR/icono.svg"
  valid_icon_png "$APP_ICON" 2>/dev/null && return 1
  instalar_nemo >/dev/null || return 1
  valid_icon_png "$APP_ICON" || return 1
  assert_absent "$APP_DIR/renombrador.png" || return 1
  assert_absent "$APP_DIR/icono.svg" || return 1
}

icon_symlink_safety_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  mkdir -p "${APP_ICON%/*}"
  printf outside > "$CASE_DIR/outside"
  ln -s "$CASE_DIR/outside" "$APP_ICON"
  set +e
  instalar_icono
  local rc=$?
  set -e
  (( rc != 0 )) || return 1
  [[ -L "$APP_ICON" ]] || return 1
  assert_content "$CASE_DIR/outside" 'outside' || return 1
}

# GTK only notices a new icon (and ignores a stale icon-theme.cache) when the theme root changes.
icon_theme_refresh_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  local cache="$APP_ICON_THEME/icon-theme.cache"
  mkdir -p "$APP_ICON_THEME/64x64/apps"
  printf x > "$cache"
  touch -d 2001-01-01 "$cache" "$APP_ICON_THEME"
  instalar_nemo >/dev/null || return 1
  (( $(stat -c %Y "$APP_ICON_THEME") > $(stat -c %Y "$cache") )) || return 1
  touch -d 2001-01-01 "$APP_ICON_THEME"
  refrescar_accion_nemo || return 1
  (( $(stat -c %Y "$APP_ICON_THEME") > $(stat -c %Y "$cache") )) || return 1
  mkdir -p "$CASE_DIR/bin"
  printf '#!/bin/sh\nexit 1\n' > "$CASE_DIR/bin/touch"
  chmod +x "$CASE_DIR/bin/touch"
  PATH="$CASE_DIR/bin:$PATH"; hash -r
  instalar_icono || return 1
  valid_icon_png "$APP_ICON"
}

nemo_toggle_lifecycle_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  mkdir -p "$CASE_DIR/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CASE_DIR/bin/nemo"
  chmod +x "$CASE_DIR/bin/nemo"
  export PATH="$CASE_DIR/bin:$PATH"
  source "$SCRIPT"

  # No installation yet: toggling must fail cleanly, nothing created.
  desactivar_nemo 2>/dev/null && return 1
  assert_absent "$NEMO_ACTION" || return 1

  instalar_nemo || return 1
  nemo_activo || return 1
  grep -Fqx 'Active=true' "$NEMO_ACTION" || return 1
  local icon_before icon_after
  icon_before=$(cksum < "$APP_ICON")

  desactivar_nemo || return 1
  nemo_activo && return 1
  grep -Fqx 'Active=false' "$NEMO_ACTION" || return 1
  assert_file "$APP_ICON" || return 1
  icon_after=$(cksum < "$APP_ICON")
  [[ "$icon_before" == "$icon_after" ]] || return 1

  activar_nemo || return 1
  nemo_activo || return 1
  grep -Fqx 'Active=true' "$NEMO_ACTION" || return 1

  # Same two flags as exercised via the CLI entry point.
  capture_cli en --desactivar-nemo
  (( CLI_RC == 0 )) || return 1
  grep -Fqx 'Active=false' "$NEMO_ACTION" || return 1

  capture_cli en --activar-nemo
  (( CLI_RC == 0 )) || return 1
  grep -Fqx 'Active=true' "$NEMO_ACTION" || return 1
}

nemo_manage_menu_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  mkdir -p "$CASE_DIR/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CASE_DIR/bin/nemo"
  chmod +x "$CASE_DIR/bin/nemo"
  export PATH="$CASE_DIR/bin:$PATH"
  source "$SCRIPT"
  instalar_nemo >/dev/null || return 1

  local out
  out=$(gestionar_nemo <<< 'a' 2>&1)
  assert_contains "$out" 'deactivated' || return 1
  nemo_activo && return 1

  out=$(gestionar_nemo <<< 'a' 2>&1)
  assert_contains "$out" 'activated' || return 1
  nemo_activo || return 1

  out=$(gestionar_nemo <<< $'q\nn' 2>&1)
  assert_contains "$out" 'Cancelled' || return 1
  assert_file "$NEMO_ACTION" || return 1

  assert_file "$APP_ICON" || return 1
  out=$(gestionar_nemo <<< $'q\ny' 2>&1)
  assert_contains "$out" 'removed' || return 1
  assert_absent "$NEMO_ACTION" || return 1
  assert_absent "$APP_ICON" || return 1
}

nemo_uninstall_failure_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  mkdir -p "$CASE_DIR/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CASE_DIR/bin/nemo"
  chmod +x "$CASE_DIR/bin/nemo"
  export PATH="$CASE_DIR/bin:$PATH"
  source "$SCRIPT"
  instalar_nemo >/dev/null || return 1

  # A failing rm must not be reported as success (rm stub, since root ignores chmod).
  printf '#!/usr/bin/env bash\nexit 1\n' > "$CASE_DIR/bin/rm"
  chmod +x "$CASE_DIR/bin/rm"; hash -r  # instalar_nemo already cached the real rm
  local out rc
  out=$(desinstalar_nemo 2>&1); rc=$?
  (( rc != 0 )) || return 1
  assert_contains "$out" 'Could not remove' || return 1
  [[ "$out" != *'action removed'* ]] || return 1
  assert_file "$NEMO_ACTION" || return 1
  assert_file "$APP_ICON" || return 1

  capture_cli en --desinstalar-nemo
  (( CLI_RC == 1 )) || return 1
  assert_file "$NEMO_ACTION" || return 1

  /usr/bin/rm "$CASE_DIR/bin/rm"; hash -r  # forget the removed stub's cached path
  capture_cli en --desinstalar-nemo
  (( CLI_RC == 0 )) || return 1
  assert_absent "$NEMO_ACTION" || return 1
  assert_absent "$APP_ICON" || return 1
}

config_symlink_safety_test() {
  new_case
  mkdir -p "$CASE_HOME/.config/renombrador"
  printf outside > "$CASE_DIR/outside.conf"
  ln -s "$CASE_DIR/outside.conf" "$CASE_HOME/.config/renombrador/plantillas.conf"
  set +e
  cli_dry_run >/dev/null 2>&1
  local rc=$?
  set -e
  (( rc != 0 )) || return 1
  [[ -L "$CASE_HOME/.config/renombrador/plantillas.conf" ]] || return 1
  assert_content "$CASE_DIR/outside.conf" 'outside' || return 1
}

config_dir_permissions_test() {
  new_case
  cli_dry_run >/dev/null 2>&1 || return 1
  [[ "$(stat -c '%a' "$CASE_HOME/.config/renombrador")" == "700" ]] || return 1
  [[ "$(stat -c '%a' "$CASE_HOME/.config/renombrador/historial")" == "700" ]] || return 1
}

config_dir_permissions_upgrade_test() {
  new_case
  mkdir -p "$CASE_HOME/.config/renombrador/historial"
  chmod 755 "$CASE_HOME/.config/renombrador" "$CASE_HOME/.config/renombrador/historial"
  cli_dry_run >/dev/null 2>&1 || return 1
  [[ "$(stat -c '%a' "$CASE_HOME/.config/renombrador")" == "700" ]] || return 1
  [[ "$(stat -c '%a' "$CASE_HOME/.config/renombrador/historial")" == "700" ]] || return 1
}


history_fingerprint_failure_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  printf content > "$CASE_DIR/a.txt"
  mkdir -p "$CASE_DIR/bin"
  cat > "$CASE_DIR/bin/tar" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$CASE_DIR/bin/tar"
  local hash
  set +e
  hash=$(PATH="$CASE_DIR/bin:$PATH" huella_ruta "$CASE_DIR/a.txt")
  local rc=$?
  set -e
  (( rc != 0 )) || return 1
  [[ -z "$hash" ]] || return 1
}

history_fingerprint_stability_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  mkdir "$CASE_DIR/dir"
  printf 'content' > "$CASE_DIR/dir/a.txt"
  h1=$(huella_ruta "$CASE_DIR/dir") || return 1
  h2=$(huella_ruta "$CASE_DIR/dir") || return 1
  [[ "$h1" == "$h2" && "$h1" =~ ^[0-9a-f]{64}$ ]] || return 1
  touch "$CASE_DIR/dir/a.txt"
  h3=$(huella_ruta "$CASE_DIR/dir") || return 1
  [[ "$h3" == "$h1" ]] || return 1
  printf 'changed' > "$CASE_DIR/dir/a.txt"
  h4=$(huella_ruta "$CASE_DIR/dir") || return 1
  [[ "$h4" != "$h1" ]] || return 1
  mv "$CASE_DIR/dir" "$CASE_DIR/renamed"
  h5=$(huella_ruta "$CASE_DIR/renamed") || return 1
  [[ "$h5" == "$h4" ]] || return 1
}

template_import_atomicity_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  printf 'Existing|E_{name}.{ext}\n' > "$TEMPLATES_FILE"
  printf 'New|N_{name}.{ext}\nAnother|A_{name}.{ext}\n' > "$CASE_DIR/import.txt"
  SELECTOR=zenity
  CLI_MODE=1
  mkdir -p "$CASE_DIR/bin"
  cat > "$CASE_DIR/bin/zenity" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$CASE_DIR/import.txt'
EOF
  cat > "$CASE_DIR/bin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "${@: -1}" == "$CASE_HOME/.config/renombrador/plantillas.conf" ]]; then exit 1; fi
exec /usr/bin/mv "$@"
EOF
  chmod +x "$CASE_DIR/bin/zenity" "$CASE_DIR/bin/mv"
  export CASE_DIR CASE_HOME PATH="$CASE_DIR/bin:$PATH"
  set +e
  PATH="$CASE_DIR/bin:$PATH" importar_plantillas >/dev/null 2>&1
  rc=$?
  set -e
  (( rc != 0 )) || return 1
  assert_content "$TEMPLATES_FILE" $'Existing|E_{name}.{ext}\n' || return 1

  rm -f "$CASE_DIR/bin/mv"
  importar_plantillas >/dev/null 2>&1
  assert_content "$TEMPLATES_FILE" $'Existing|E_{name}.{ext}\nNew|N_{name}.{ext}\nAnother|A_{name}.{ext}\n' || return 1
}

template_read_failure_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  printf 'Existing|E_{name}.{ext}\n' > "$TEMPLATES_FILE"
  printf 'New|N_{name}.{ext}\n' > "$CASE_DIR/import.txt"
  SELECTOR=zenity
  # shellcheck disable=SC2034  # read by the sourced CLI
  CLI_MODE=1
  mkdir -p "$CASE_DIR/bin"
  cat > "$CASE_DIR/bin/zenity" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$CASE_DIR/import.txt'
EOF
  cat > "$CASE_DIR/bin/cat" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do [[ "$arg" == "$TARGET_TEMPLATES" ]] && exit 1; done
exec /usr/bin/cat "$@"
EOF
  chmod +x "$CASE_DIR/bin/zenity" "$CASE_DIR/bin/cat"
  local before after
  before=$(cat "$TEMPLATES_FILE")
  export TARGET_TEMPLATES="$TEMPLATES_FILE" PATH="$CASE_DIR/bin:$PATH"
  set +e
  importar_plantillas >/dev/null 2>&1
  local rc=$?
  set -e
  (( rc != 0 )) || return 1
  after=$(/usr/bin/cat "$TEMPLATES_FILE")
  [[ "$before" == "$after" ]] || return 1
}

# Fake file picker: logs its arguments, prints $PICK (fails like a cancelled
# dialog when empty).
fake_picker() {
  mkdir -p "$CASE_DIR/bin"
  cat > "$CASE_DIR/bin/$1" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CASE_DIR/picker.log"
[[ -n "${PICK:-}" ]] || exit 1
printf '%s\n' "$PICK"
EOF
  chmod +x "$CASE_DIR/bin/$1"
  export PATH="$CASE_DIR/bin:$PATH"
}

# Call after sourcing the script (sourcing here would make its tables local to
# this function): queue of a.txt and b.txt, zenity faked.
template_flow_setup() {
  printf x > "$CASE_DIR/a.txt"; printf x > "$CASE_DIR/b.txt"
  SELECTOR=zenity
  FILES=("$CASE_DIR/a.txt" "$CASE_DIR/b.txt")
  reiniciar_cola
  fake_picker zenity
}

# Runs "$@" in this shell with "$1" plus a SENTINEL line on stdin. Without a
# terminal read -p prints no prompt, so a question is detected by how much input
# is consumed: OUT is the output, LEFT the unread input, RC the exit status.
run_fed() {
  printf '%s\nSENTINEL\n' "$1" > "$CASE_DIR/in.txt"
  shift
  { "$@" > "$CASE_DIR/out.txt" 2>&1; RC=$?; cat > "$CASE_DIR/left.txt"; } < "$CASE_DIR/in.txt"
  OUT=$(< "$CASE_DIR/out.txt"); LEFT=$(< "$CASE_DIR/left.txt")
}

usar_plantilla_importar_aplicar_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  template_flow_setup
  printf 'Pre|PRE_{name}.{ext}\nSuf|{name}_SUF.{ext}\n' > "$CASE_DIR/import.txt"
  export PICK="$CASE_DIR/import.txt"
  run_fed $'s\n1' usar_plantilla_guardada
  [[ "$LEFT" == SENTINEL ]] || return 1
  assert_file "$CASE_DIR/picker.log" || return 1
  assert_contains "$OUT" '2 template(s) imported' || return 1
  assert_contains "$OUT" 'Applying «Pre»' || return 1
  assert_content "$TEMPLATES_FILE" $'Pre|PRE_{name}.{ext}\nSuf|{name}_SUF.{ext}\n' || return 1
  [[ "${NOMBRES_COLA[0]}" == PRE_a.txt && "${NOMBRES_COLA[1]}" == PRE_b.txt ]] || return 1
}

usar_plantilla_respuesta_n_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  template_flow_setup
  export PICK="$CASE_DIR/import.txt"
  printf 'Pre|PRE_{name}.{ext}\n' > "$PICK"
  run_fed n usar_plantilla_guardada
  (( RC == 0 )) || return 1
  [[ "$LEFT" == SENTINEL ]] || return 1
  assert_absent "$CASE_DIR/picker.log" || return 1
  [[ ! -s "$TEMPLATES_FILE" ]] || return 1
  [[ "${NOMBRES_COLA[*]}" == 'a.txt b.txt' ]] && (( ${#PASOS_COLA[@]} == 0 )) || return 1
}

usar_plantilla_cancelar_dialogo_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  template_flow_setup
  export PICK=
  run_fed $'s\n' usar_plantilla_guardada
  (( RC == 0 )) || return 1
  [[ "$LEFT" == SENTINEL ]] || return 1
  assert_file "$CASE_DIR/picker.log" || return 1
  assert_contains "$OUT" 'Cancelled.' || return 1
  [[ ! -s "$TEMPLATES_FILE" ]] || return 1
  [[ "${NOMBRES_COLA[*]}" == 'a.txt b.txt' ]] && (( ${#PASOS_COLA[@]} == 0 )) || return 1
}

importar_plantillas_rechaza_binario_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  template_flow_setup
  local f i pad
  printf -v pad '%*s' 1017 ''; pad=${pad// /x}
  for ((i = 1; i <= 1024; i++)); do printf 'T%04d|%s\n' "$i" "$pad"; done > "$CASE_DIR/ok.txt"
  { cat -- "$CASE_DIR/ok.txt"; printf '\n'; } > "$CASE_DIR/big.txt"
  { head -c 1048575 "$CASE_DIR/ok.txt"; printf '\0'; } > "$CASE_DIR/nul.txt"
  printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR' > "$CASE_DIR/img.png"
  [[ "$(stat -c %s "$CASE_DIR/ok.txt")" == 1048576 && "$(stat -c %s "$CASE_DIR/nul.txt")" == 1048576 ]] || return 1
  for f in img.png nul.txt big.txt; do
    export PICK="$CASE_DIR/$f"
    run_fed '' importar_plantillas_desde_archivo
    (( RC == 0 )) || return 1
    assert_contains "$OUT" 'does not look like text' || return 1
    [[ ! -s "$TEMPLATES_FILE" ]] || return 1
  done
  export PICK="$CASE_DIR/ok.txt"
  run_fed '' importar_plantillas_desde_archivo
  (( RC == 0 )) || return 1
  assert_contains "$OUT" '1024 template(s) imported' || return 1
  cmp -s "$CASE_DIR/ok.txt" "$TEMPLATES_FILE" || return 1
}

importar_plantillas_limpia_crlf_bom_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  template_flow_setup
  printf '\xEF\xBB\xBFPre|PRE_{name}.{ext}\r\nSuf|{name}_SUF.{ext}\r\n\r\nLast|L_{name}.{ext}\r' > "$CASE_DIR/win.txt"
  export PICK="$CASE_DIR/win.txt"
  run_fed '' importar_plantillas_desde_archivo
  (( RC == 0 )) || return 1
  assert_contains "$OUT" '3 template(s) imported (0 duplicate(s) skipped, 0 invalid line(s))' || return 1
  assert_content "$TEMPLATES_FILE" $'Pre|PRE_{name}.{ext}\nSuf|{name}_SUF.{ext}\nLast|L_{name}.{ext}\n' || return 1
}

# Runs the import with selector $1 from script $2 (cancelled dialog); the
# arguments the fake picker received end up in ARGS.
picker_args() {
  rm -f "$CASE_DIR/picker.log"
  PICK='' bash -c 'source "$2"; SELECTOR=$1; importar_plantillas_desde_archivo' _ "$1" "$2" >/dev/null 2>&1
  mapfile -t ARGS < "$CASE_DIR/picker.log"
}

importar_plantillas_directorio_inicial_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  fake_picker zenity; fake_picker kdialog
  local dir copy="$CASE_DIR/copy/script/renombrador.sh"
  dir=$(realpath -e -- "$ROOT_DIR/assets/templates") || return 1
  mkdir -p "${copy%/*}" && cp -- "$SCRIPT" "$copy" || return 1

  picker_args zenity "$SCRIPT"
  [[ "${#ARGS[@]}" == 3 && "${ARGS[0]}" == --file-selection && "${ARGS[1]}" == "--filename=$dir/" \
    && "${ARGS[2]}" == '--title=Import templates' ]] || return 1
  picker_args kdialog "$SCRIPT"
  [[ "${ARGS[0]}" == --getopenfilename && "${ARGS[1]}" == "$dir" ]] || return 1

  picker_args zenity "$copy"
  [[ "${#ARGS[@]}" == 2 && "${ARGS[0]}" == --file-selection && "${ARGS[1]}" == '--title=Import templates' ]] || return 1
  picker_args kdialog "$copy"
  [[ "${ARGS[0]}" == --getopenfilename && "${ARGS[1]}" == "$HOME" ]] || return 1
}

usar_plantilla_con_almacen_sin_pregunta_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  template_flow_setup
  printf 'Num|{n}_{name}.{ext}\n' > "$TEMPLATES_FILE"
  run_fed $'1\n5\n2' usar_plantilla_guardada
  (( RC == 0 )) || return 1
  [[ "$LEFT" == SENTINEL ]] || return 1
  assert_absent "$CASE_DIR/picker.log" || return 1
  [[ "${NOMBRES_COLA[*]}" == '05_a.txt 06_b.txt' ]] || return 1
}

importar_plantillas_sin_validas_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  template_flow_setup
  # shellcheck disable=SC2034  # read by the sourced CLI
  C_OK='<ok>' C_WARN='<warn>'
  local spec msg
  printf '' > "$CASE_DIR/empty.txt"
  printf '\n  \n\t\r\n' > "$CASE_DIR/blank.txt"
  printf 'no pipe\n|no name\nno pattern|\n' > "$CASE_DIR/bad.txt"
  printf '   \nno pipe\n\r\n' > "$CASE_DIR/mixed.txt"
  for spec in empty:0 blank:0 bad:3 mixed:1; do
    export PICK="$CASE_DIR/${spec%:*}.txt"
    run_fed '' importar_plantillas_desde_archivo
    (( RC == 0 )) || return 1
    msg="No templates imported: the file has no valid lines in the «Name|Pattern» format (${spec#*:} invalid line(s))."
    assert_contains "$OUT" "<warn>$I_WARN $msg" || return 1
    [[ "$OUT" != *'<ok>'* && ! -s "$TEMPLATES_FILE" ]] || return 1
  done

  # Duplicates and partly valid files are not failures: they stay green.
  printf 'Pre|PRE_{name}.{ext}\n' > "$TEMPLATES_FILE"
  printf 'Pre|OTHER\n' > "$CASE_DIR/dup.txt"
  export PICK="$CASE_DIR/dup.txt"
  run_fed '' importar_plantillas_desde_archivo
  assert_contains "$OUT" "<ok>$I_OK 0 template(s) imported (1 duplicate(s) skipped, 0 invalid line(s))." || return 1
  [[ "$OUT" != *'<warn>'* ]] || return 1
  printf 'New|N_{name}.{ext}\nbad\n' > "$CASE_DIR/some.txt"
  export PICK="$CASE_DIR/some.txt"
  run_fed '' importar_plantillas_desde_archivo
  assert_contains "$OUT" "<ok>$I_OK 1 template(s) imported (0 duplicate(s) skipped, 1 invalid line(s))." || return 1
  [[ "$OUT" != *'<warn>'* ]] || return 1

  # shellcheck disable=SC2034  # read by the sourced CLI
  APP_LANG=es
  export PICK="$CASE_DIR/bad.txt"
  run_fed '' importar_plantillas_desde_archivo
  assert_contains "$OUT" "<warn>$I_WARN Ninguna plantilla importada: el archivo no tiene líneas válidas con el formato «Nombre|Patrón».  (3 línea(s) no válida(s))" || return 1
  [[ "$OUT" != *'<ok>'* ]] || return 1
}

importar_plantillas_archivo_ilegible_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  template_flow_setup
  : > "$CASE_DIR/empty.txt"
  printf 'A|B\n' > "$CASE_DIR/full.txt"
  chmod 000 "$CASE_DIR/empty.txt" "$CASE_DIR/full.txt"
  if { : < "$CASE_DIR/full.txt"; } 2>/dev/null; then
    skip "importar_plantillas_archivo_ilegible_test (los permisos actuales ignoran chmod 000, p. ej. root)"
    return 77
  fi
  local f
  for f in empty full; do
    export PICK="$CASE_DIR/$f.txt"
    run_fed '' importar_plantillas_desde_archivo
    (( RC == 0 )) || return 1
    assert_contains "$OUT" 'The file cannot be read' || return 1
    [[ "$OUT" != *'Permission denied'* && "$OUT" != *'No templates imported'* && ! -s "$TEMPLATES_FILE" ]] || return 1
  done
}

importar_plantillas_recorta_espacios_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  template_flow_setup
  printf 'Uno | {name}_x \n |{name}\n\t Dos \t|\t{name}\nTres|   \n  |  \nCuatro|a | b\nSeis|| {name}\nEs\\c|{name}\\_x\n' > "$CASE_DIR/space.txt"
  export PICK="$CASE_DIR/space.txt"
  run_fed '' importar_plantillas_desde_archivo
  (( RC == 0 )) || return 1
  assert_contains "$OUT" '5 template(s) imported (0 duplicate(s) skipped, 3 invalid line(s))' || return 1
  assert_content "$TEMPLATES_FILE" $'Uno|{name}_x\nDos|{name}\nCuatro|a  b\nSeis|{name}\nEs\\c|{name}\\_x\n' || return 1

  printf '  Uno  |OTHER\n' > "$CASE_DIR/dup.txt"
  export PICK="$CASE_DIR/dup.txt"
  run_fed '' importar_plantillas_desde_archivo
  assert_contains "$OUT" '0 template(s) imported (1 duplicate(s) skipped, 0 invalid line(s))' || return 1
  assert_content "$TEMPLATES_FILE" $'Uno|{name}_x\nDos|{name}\nCuatro|a  b\nSeis|{name}\nEs\\c|{name}\\_x\n' || return 1
}

flock_plantillas_concurrency_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  mkdir -p "$CASE_DIR/bin"
  export TARGET_TEMPLATES="$TEMPLATES_FILE"
  # Delays only the read inside guardar_plantilla's critical section, widening
  # the race window so a broken/missing flock would reliably lose writes.
  cat > "$CASE_DIR/bin/cat" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do [[ "$arg" == "$TARGET_TEMPLATES" ]] && sleep 0.3; done
exec /usr/bin/cat "$@"
EOF
  chmod +x "$CASE_DIR/bin/cat"
  export PATH="$CASE_DIR/bin:$PATH"

  local n=8 i pid pids=() rc=0
  for ((i = 1; i <= n; i++)); do
    ( printf 'Plantilla_%d\nPatron_%d\n' "$i" "$i" | guardar_plantilla >/dev/null 2>&1 ) &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
  (( rc == 0 )) || return 1

  [[ "$(grep -c '' "$TEMPLATES_FILE")" == "$n" ]] || return 1
  for ((i = 1; i <= n; i++)); do
    grep -qxF "Plantilla_$i|Patron_$i" "$TEMPLATES_FILE" || return 1
  done
  [[ -f "$PLANTILLAS_LOCK_FILE" && ! -L "$PLANTILLAS_LOCK_FILE" ]] || return 1
}

history_write_atomicity_test() {
  new_case
  printf 'x' > "$CASE_DIR/a.txt"
  mkdir -p "$CASE_DIR/bin"
  cat > "$CASE_DIR/bin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "${@: -1}" == *.log ]]; then exit 1; fi
exec /usr/bin/mv "$@"
EOF
  chmod +x "$CASE_DIR/bin/mv"
  export PATH="$CASE_DIR/bin:$PATH"
  capture_cli en --archivo "$CASE_DIR/a.txt" --metodo prefijo --prefijo X_ --sin-confirmar
  (( CLI_RC == 1 )) || return 1
  assert_file "$CASE_DIR/a.txt" || return 1
  assert_absent "$CASE_DIR/X_a.txt" || return 1
  [[ -z "$(find "$CASE_HOME/.config/renombrador/historial" -maxdepth 1 -name '*.log' -print -quit)" ]] || return 1
  [[ -z "$(find "$CASE_HOME/.config/renombrador/historial" -maxdepth 1 -name '*.log.tmp.*' -print -quit)" ]] || return 1
}

history_copy_write_atomicity_test() {
  new_case
  printf 'x' > "$CASE_DIR/a.txt"
  mkdir -p "$CASE_DIR/bin"
  cat > "$CASE_DIR/bin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "${@: -1}" == *.log ]]; then exit 1; fi
exec /usr/bin/mv "$@"
EOF
  chmod +x "$CASE_DIR/bin/mv"
  export PATH="$CASE_DIR/bin:$PATH"
  capture_cli en --archivo "$CASE_DIR/a.txt" --metodo prefijo --prefijo X_ --modo copiar --sin-confirmar
  (( CLI_RC == 1 )) || return 1
  assert_file "$CASE_DIR/a.txt" || return 1
  assert_absent "$CASE_DIR/X_a.txt" || return 1
  [[ -z "$(find "$CASE_HOME/.config/renombrador/historial" -maxdepth 1 -name '*.log' -print -quit)" ]] || return 1
}

# A signal caught mid-batch must be deferred until the batch reaches a
# consistent state (both rename phases done, history written), not acted
# on immediately -- otherwise items are stranded under .renombrador_tmp_*
# with no history entry to undo them.
signal_apply_move_deferred_test() {
  new_case
  printf a > "$CASE_DIR/a.txt"
  printf b > "$CASE_DIR/b.txt"
  mkdir -p "$CASE_DIR/bin"
  cat > "$CASE_DIR/bin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "${@: -1}" == *.renombrador_tmp_* ]]; then kill -TERM "$PPID"; sleep 0.1; fi
exec /usr/bin/mv "$@"
EOF
  chmod +x "$CASE_DIR/bin/mv"
  export PATH="$CASE_DIR/bin:$PATH"
  capture_cli en --archivo "$CASE_DIR/a.txt" --archivo "$CASE_DIR/b.txt" --metodo prefijo --prefijo X_ --sin-confirmar
  (( CLI_RC == 143 )) || return 1
  assert_contains "$CLI_OUTPUT" 'Interrupted.' || return 1
  assert_file "$CASE_DIR/X_a.txt" || return 1
  assert_file "$CASE_DIR/X_b.txt" || return 1
  assert_absent "$CASE_DIR/a.txt" || return 1
  assert_absent "$CASE_DIR/b.txt" || return 1
  [[ -z "$(find "$CASE_DIR" -maxdepth 1 -name '.renombrador_tmp_*' -print -quit)" ]] || return 1
  [[ -n "$(find "$CASE_HOME/.config/renombrador/historial" -maxdepth 1 -name '*.log' -print -quit)" ]] || return 1
}

# Each copy is independently atomic, so a signal polls and stops the loop
# early instead of deferring through every remaining item.
signal_apply_copy_partial_test() {
  new_case
  printf a > "$CASE_DIR/a.txt"
  printf b > "$CASE_DIR/b.txt"
  printf c > "$CASE_DIR/c.txt"
  mkdir -p "$CASE_DIR/bin"
  cat > "$CASE_DIR/bin/cp" <<EOF
#!/usr/bin/env bash
marker="$CASE_DIR/.signaled"
if [[ ! -e "\$marker" ]]; then : > "\$marker"; kill -TERM "\$PPID"; sleep 0.1; fi
exec /usr/bin/cp "\$@"
EOF
  chmod +x "$CASE_DIR/bin/cp"
  export PATH="$CASE_DIR/bin:$PATH"
  capture_cli en --archivo "$CASE_DIR/a.txt" --archivo "$CASE_DIR/b.txt" --archivo "$CASE_DIR/c.txt" --metodo prefijo --prefijo C_ --modo copiar --sin-confirmar
  (( CLI_RC == 143 )) || return 1
  assert_contains "$CLI_OUTPUT" 'Interrupted.' || return 1
  assert_file "$CASE_DIR/C_a.txt" || return 1
  assert_absent "$CASE_DIR/C_b.txt" || return 1
  assert_absent "$CASE_DIR/C_c.txt" || return 1
  assert_file "$CASE_DIR/b.txt" || return 1
  assert_file "$CASE_DIR/c.txt" || return 1
  [[ -z "$(find "$CASE_DIR" -maxdepth 1 -name '.renombrador_stage.*' -print -quit)" ]] || return 1
  local log; log=$(find "$CASE_HOME/.config/renombrador/historial" -maxdepth 1 -name '*.log' -print -quit)
  [[ -n "$log" ]] || return 1
  (( $(grep -vc '^#' "$log") == 1 )) || return 1
}

barrer_huerfanos_sweep_test() {
  new_case
  printf a > "$CASE_DIR/a.txt"
  mkdir -p "$CASE_DIR/.renombrador_stage.old"
  : > "$CASE_DIR/.renombrador_tmp_old_0"
  : > "$CASE_DIR/.renombrador_undo_tmp_old_0"
  : > "$CASE_DIR/.renombrador_backup_old_0"
  capture_cli en --archivo "$CASE_DIR/a.txt" --metodo prefijo --prefijo X_ --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_file "$CASE_DIR/X_a.txt" || return 1
  assert_absent "$CASE_DIR/.renombrador_stage.old" || return 1
  # tmp/undo_tmp/backup may hold the only copy of a user's item: kept + reported.
  assert_file "$CASE_DIR/.renombrador_tmp_old_0" || return 1
  assert_file "$CASE_DIR/.renombrador_undo_tmp_old_0" || return 1
  assert_file "$CASE_DIR/.renombrador_backup_old_0" || return 1
  assert_contains "$CLI_OUTPUT" '3 item(s) left by an interrupted run' || return 1
}

# deshacer_ultimo shares aplicar_renombrado's two-phase move, so it needs
# the same deferral: both restore phases must finish before an interrupt
# is honored.
signal_undo_move_deferred_test() {
  new_case
  printf original > "$CASE_DIR/a.txt"
  capture_cli en --archivo "$CASE_DIR/a.txt" --metodo prefijo --prefijo M_ --modo mover --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  mkdir -p "$CASE_DIR/bin"
  cat > "$CASE_DIR/bin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "${@: -1}" == *.renombrador_undo_tmp_* ]]; then kill -TERM "$PPID"; sleep 0.1; fi
exec /usr/bin/mv "$@"
EOF
  chmod +x "$CASE_DIR/bin/mv"
  local undo_output undo_rc
  undo_output=$(printf '1\n\n' | (export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en PATH="$CASE_DIR/bin:$PATH"; source "$SCRIPT"; deshacer_ultimo) 2>&1)
  undo_rc=$?
  (( undo_rc == 143 )) || return 1
  assert_contains "$undo_output" 'Interrupted.' || return 1
  assert_file "$CASE_DIR/a.txt" || return 1
  assert_absent "$CASE_DIR/M_a.txt" || return 1
  [[ -z "$(find "$CASE_DIR" -maxdepth 1 -name '.renombrador_undo_tmp_*' -print -quit)" ]] || return 1
  [[ -z "$(find "$CASE_HOME/.config/renombrador/historial" -maxdepth 1 -name '*.log' -print -quit)" ]] || return 1
}

# The copy-undo loop deletes items one at a time (each deletion already
# atomic); items not yet reached when a signal lands must stay in
# "pendientes" instead of falling out of history.
signal_undo_copy_partial_test() {
  new_case
  printf a > "$CASE_DIR/a.txt"
  printf b > "$CASE_DIR/b.txt"
  printf c > "$CASE_DIR/c.txt"
  capture_cli en --archivo "$CASE_DIR/a.txt" --archivo "$CASE_DIR/b.txt" --archivo "$CASE_DIR/c.txt" --metodo prefijo --prefijo C_ --modo copiar --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  mkdir -p "$CASE_DIR/bin"
  cat > "$CASE_DIR/bin/rm" <<EOF
#!/usr/bin/env bash
marker="$CASE_DIR/.signaled"
if [[ ! -e "\$marker" ]]; then : > "\$marker"; kill -TERM "\$PPID"; sleep 0.1; fi
exec /usr/bin/rm "\$@"
EOF
  chmod +x "$CASE_DIR/bin/rm"
  local undo_output undo_rc
  undo_output=$(printf '1\n\n' | (export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en PATH="$CASE_DIR/bin:$PATH"; source "$SCRIPT"; deshacer_ultimo) 2>&1)
  undo_rc=$?
  (( undo_rc == 143 )) || return 1
  assert_contains "$undo_output" 'Interrupted.' || return 1
  assert_absent "$CASE_DIR/C_a.txt" || return 1
  assert_file "$CASE_DIR/C_b.txt" || return 1
  assert_file "$CASE_DIR/C_c.txt" || return 1
  local log; log=$(find "$CASE_HOME/.config/renombrador/historial" -maxdepth 1 -name '*.log' -print -quit)
  [[ -n "$log" ]] || return 1
  (( $(grep -vc '^#' "$log") == 2 )) || return 1
}

history_overwrite_rollback_test() {
  new_case
  printf src > "$CASE_DIR/a.txt"
  printf old > "$CASE_DIR/target.txt"
  mkdir -p "$CASE_DIR/bin"
  cat > "$CASE_DIR/bin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "${@: -1}" == *.log ]]; then exit 1; fi
exec /usr/bin/mv "$@"
EOF
  chmod +x "$CASE_DIR/bin/mv"
  export PATH="$CASE_DIR/bin:$PATH"

  capture_cli en --archivo "$CASE_DIR/a.txt" --metodo buscar-reemplazar --buscar 'a' --reemplazar 'target' --conflicto sobrescribir --sin-confirmar
  (( CLI_RC == 1 )) || return 1
  assert_content "$CASE_DIR/a.txt" 'src' || return 1
  assert_content "$CASE_DIR/target.txt" 'old' || return 1

  capture_cli en --archivo "$CASE_DIR/a.txt" --metodo buscar-reemplazar --buscar 'a' --reemplazar 'target' --modo copiar --conflicto sobrescribir --sin-confirmar
  (( CLI_RC == 1 )) || return 1
  assert_content "$CASE_DIR/a.txt" 'src' || return 1
  assert_content "$CASE_DIR/target.txt" 'old' || return 1
  [[ -z "$(find "$CASE_DIR" -maxdepth 1 -name '.renombrador_backup_*' -print -quit)" ]] || return 1
}

history_fingerprint_apply_failure_test() {
  new_case
  printf 'x' > "$CASE_DIR/a.txt"
  mkdir -p "$CASE_DIR/bin"
  cat > "$CASE_DIR/bin/tar" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$CASE_DIR/bin/tar"
  export PATH="$CASE_DIR/bin:$PATH"
  capture_cli en --archivo "$CASE_DIR/a.txt" --metodo prefijo --prefijo X_ --sin-confirmar
  (( CLI_RC == 1 )) || return 1
  assert_file "$CASE_DIR/a.txt" || return 1
  assert_absent "$CASE_DIR/X_a.txt" || return 1
  [[ -z "$(find "$CASE_HOME/.config/renombrador/historial" -maxdepth 1 -name '*.log' -print -quit)" ]] || return 1
}

adversarial_filenames_test() {
  new_case
  local f1 f2 f3 f4 f5
  f1="$CASE_DIR/-leading.txt"
  f2="$CASE_DIR/space name.txt"
  f3="$CASE_DIR/semi;literal.txt"
  f4="$CASE_DIR/quote'\".txt"
  f5="$CASE_DIR/"$'line\nname.txt'
  printf a > "$f1"; printf b > "$f2"; printf c > "$f3"; printf d > "$f4"; printf e > "$f5"
  local args=(--archivo "$f1" --archivo "$f2" --archivo "$f3" --archivo "$f4" --archivo "$f5" --metodo prefijo --prefijo 'X_' --sin-confirmar)
  capture_cli en "${args[@]}"
  (( CLI_RC == 0 )) || { printf '%s\n' "$CLI_OUTPUT" >&2; return 1; }
  [[ -f "$CASE_DIR/X_-leading.txt" ]] || return 1
  [[ -f "$CASE_DIR/X_space name.txt" ]] || return 1
  [[ -f "$CASE_DIR/X_semi;literal.txt" ]] || return 1
  [[ -f "$CASE_DIR/X_quote'\".txt" ]] || return 1
  [[ -f "$CASE_DIR/X_line"$'\n'"name.txt" ]] || return 1
  [[ ! -e "$CASE_DIR/HACKED" ]] || return 1
  rm -f -- "$CASE_DIR/X_-leading.txt" "$CASE_DIR/X_space name.txt" "$CASE_DIR/X_semi;literal.txt" "$CASE_DIR/X_quote'\".txt" "$CASE_DIR/X_line"$'\n'"name.txt"
}

translation_surface_test() {
  new_case
  capture_cli en --help
  (( CLI_RC == 0 )) || return 1
  assert_contains "$CLI_OUTPUT" 'Usage:' || return 1
  assert_contains "$CLI_OUTPUT" 'Applying changes:' || return 1
  assert_contains "$CLI_OUTPUT" '--dry-run' || return 1
  assert_contains "$CLI_OUTPUT" '--sin-confirmar' || return 1
  [[ "$CLI_OUTPUT" != *'Uso:'* ]] || return 1
  [[ "$CLI_OUTPUT" != *'Aplicación de cambios:'* ]] || return 1

  capture_cli es --lang es --help
  (( CLI_RC == 0 )) || return 1
  assert_contains "$CLI_OUTPUT" 'Uso:' || return 1
  assert_contains "$CLI_OUTPUT" 'Aplicación de cambios:' || return 1

  capture_cli en --lang xx --version
  (( CLI_RC == 2 )) || return 1
  assert_contains "$CLI_OUTPUT" 'Invalid --lang value' || return 1
}

terminal_rendering_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  capture_cli en --help
  (( CLI_RC == 0 )) || return 1
  [[ "$CLI_OUTPUT" != *$'\e'* ]] || return 1

  local rendering
  rendering=$(LC_ALL=C.UTF-8 TERM=linux RENOMBRADOR_LANG=en bash -c 'source "$1" 2>/dev/null; printf "%s|%s|%s|%s|%s" "$SIN_EMOJI" "$I_OK" "$I_ERR" "$I_ARROW" "$I_WARN"' _ "$SCRIPT" 2>/dev/null)
  [[ "$rendering" == '1|OK:|ERROR:|->|WARN:' ]] || return 1
  rendering=$(LC_ALL=C RENOMBRADOR_LANG=es bash -c 'source "$1" 2>/dev/null; printf "%s|%s" "$SIN_EMOJI" "$I_WARN"' _ "$SCRIPT" 2>/dev/null)
  [[ "$rendering" == '1|AVISO:' ]] || return 1

  # I_WARN must follow a live language switch, not just the initial detection.
  rendering=$(LC_ALL=C TERM=linux RENOMBRADOR_LANG=en bash -c '
    source "$1" 2>/dev/null
    establecer_idioma es; printf "%s|" "$I_WARN"
    cambiar_idioma >/dev/null; printf "%s" "$I_WARN"
  ' _ "$SCRIPT" 2>/dev/null)
  [[ "$rendering" == 'AVISO:|WARN:' ]] || return 1
}

lang_at_start() {
  HOME="$CASE_HOME" LC_ALL="$1" RENOMBRADOR_LANG="${2:-}" bash -c 'source "$1" 2>/dev/null; printf "%s" "$APP_LANG"' _ "$SCRIPT" 2>/dev/null
}

toggle_language() {
  HOME="$CASE_HOME" LC_ALL="${1:-C.UTF-8}" RENOMBRADOR_LANG='' bash -c 'source "$1" >/dev/null 2>&1; cambiar_idioma' _ "$SCRIPT" >/dev/null 2>&1 </dev/null
}

saved_language_test() {
  new_case
  local cfg="$CASE_HOME/.config/renombrador/idioma.conf" bad
  [[ "$(lang_at_start es_ES.UTF-8)" == es ]] || return 1

  toggle_language es_ES.UTF-8
  assert_content "$cfg" $'en\n' || return 1
  [[ "$(stat -c '%a' "$cfg")" == 600 ]] || return 1
  [[ "$(lang_at_start es_ES.UTF-8)" == en ]] || return 1
  toggle_language es_ES.UTF-8
  assert_content "$cfg" $'es\n' || return 1
  [[ "$(lang_at_start C.UTF-8)" == es ]] || return 1

  # RENOMBRADOR_LANG still wins over the saved language.
  [[ "$(lang_at_start C.UTF-8 en)" == en ]] || return 1

  printf en > "$cfg"
  [[ "$(lang_at_start es_ES.UTF-8)" == en ]] || return 1
  for bad in fr ES 'es;touch pwned' '' 'en extra'; do
    printf '%s\n' "$bad" > "$cfg"
    [[ "$(lang_at_start es_ES.UTF-8)" == es ]] || return 1
    [[ "$(lang_at_start C.UTF-8)" == en ]] || return 1
  done

  # A symlinked idioma.conf is neither read nor written through.
  rm -f "$cfg"
  printf 'es\n' > "$CASE_DIR/target"
  ln -s "$CASE_DIR/target" "$cfg"
  [[ "$(lang_at_start C.UTF-8)" == en ]] || return 1
  toggle_language C.UTF-8
  assert_content "$CASE_DIR/target" $'es\n' || return 1
  [[ -L "$cfg" ]] || return 1

  # --lang is per-run: it must not be saved.
  rm -f "$cfg"
  printf a > "$CASE_DIR/a.txt"
  HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG='' bash "$SCRIPT" --archivo "$CASE_DIR/a.txt" \
    --metodo prefijo --prefijo X_ --dry-run --lang es >/dev/null 2>&1 || return 1
  assert_absent "$cfg" || return 1
}

nemo_action_language_test() {
  new_case
  local cfg="$CASE_HOME/.config/renombrador/idioma.conf"
  local act="$CASE_HOME/.local/share/nemo/actions/renombrador.nemo_action"
  local exec_line="Exec=/bin/bash \"$CASE_HOME/.local/share/renombrador/renombrador.sh\" %F"

  # No integration installed: switching language must not create one.
  toggle_language
  assert_absent "$act" || return 1

  rm -f "$cfg"
  HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en bash "$SCRIPT" --instalar-nemo >/dev/null 2>&1 || return 1
  grep -Fqx 'Name=Rename with Renombrador...' "$act" || return 1
  grep -Fqx 'Comment=Rename the selected files or folders' "$act" || return 1
  ! grep -q '^\(Name\|Comment\)\[' "$act" || return 1
  assert_content "$cfg" $'en\n' || return 1

  HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en bash "$SCRIPT" --desactivar-nemo >/dev/null 2>&1 || return 1

  # The action follows the app language and keeps its Active state and Exec.
  toggle_language
  grep -Fqx 'Name=Renombrar con Renombrador...' "$act" || return 1
  grep -Fqx 'Comment=Renombra los archivos o carpetas seleccionadas' "$act" || return 1
  grep -Fqx 'Active=false' "$act" || return 1
  grep -Fqx "$exec_line" "$act" || return 1
  assert_content "$cfg" $'es\n' || return 1

  toggle_language
  grep -Fqx 'Name=Rename with Renombrador...' "$act" || return 1
  grep -Fqx 'Active=false' "$act" || return 1
  assert_content "$cfg" $'en\n' || return 1

  # An action written by the previous bilingual format is normalized; with no theme icon yet
  # (installs of earlier versions), the rewrite must bring it along.
  rm -f "$CASE_HOME/.local/share/icons/hicolor/64x64/apps/renombrador.png"
  cat > "$act" <<EOF
[Nemo Action]
Active=true
Name=Rename with Renombrador...
Name[es]=Renombrar con Renombrador...
Comment=Rename the selected files or folders
Comment[es]=Renombra los archivos o carpetas seleccionadas
$exec_line
Icon-Name=$CASE_HOME/.local/share/renombrador/renombrador.png
Selection=notnone
Extensions=any;
Terminal=true
EOF
  toggle_language
  grep -Fqx 'Name=Renombrar con Renombrador...' "$act" || return 1
  ! grep -q '^\(Name\|Comment\)\[' "$act" || return 1
  grep -Fqx 'Active=true' "$act" || return 1
  grep -Fqx 'Icon-Name=renombrador' "$act" || return 1
  valid_icon_png "$CASE_HOME/.local/share/icons/hicolor/64x64/apps/renombrador.png" || return 1

  # Installing with an explicit language pins it, so app and action agree.
  rm -f "$act" "$cfg"
  HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=es bash "$SCRIPT" --instalar-nemo >/dev/null 2>&1 || return 1
  grep -Fqx 'Name=Renombrar con Renombrador...' "$act" || return 1
  [[ "$(lang_at_start C.UTF-8)" == es ]] || return 1
}

locale_precedence_test() {
  new_case
  export HOME="$CASE_HOME"
  local detected
  detected=$(LC_ALL=C.UTF-8 LC_MESSAGES=es_ES.UTF-8 LANG=es_ES.UTF-8 RENOMBRADOR_LANG='' bash -c 'source "$1" 2>/dev/null; printf "%s" "$APP_LANG"' _ "$SCRIPT" 2>/dev/null)
  [[ "$detected" == en ]] || return 1

  detected=$(LC_ALL='' LC_MESSAGES=es_ES.UTF-8 LANG=en_US.UTF-8 RENOMBRADOR_LANG='' bash -c 'source "$1" 2>/dev/null; printf "%s" "$APP_LANG"' _ "$SCRIPT" 2>/dev/null)
  [[ "$detected" == es ]] || return 1

  detected=$(LC_ALL=C.UTF-8 LC_MESSAGES=es_ES.UTF-8 LANG=es_ES.UTF-8 RENOMBRADOR_LANG=en bash -c 'source "$1" 2>/dev/null; printf "%s" "$APP_LANG"' _ "$SCRIPT" 2>/dev/null)
  [[ "$detected" == en ]] || return 1
}


regex_injection_test() {
  new_case
  printf 'x.txt' > "$CASE_DIR/a.txt"
  local malicious='$'
  malicious+='(touch "$CASE_DIR/HACKED")'
  capture_cli en --archivo "$CASE_DIR/a.txt" --metodo buscar-reemplazar --buscar "$malicious" --reemplazar safe --regex --dry-run --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_contains "$CLI_OUTPUT" 'a.txt → a.txt' || return 1
  assert_file "$CASE_DIR/a.txt" || return 1
  [[ ! -e "$CASE_DIR/HACKED" ]] || return 1
}

risky_history_copy_undo_test() {
  new_case
  printf original > "$CASE_DIR/a.txt"
  capture_cli en --archivo "$CASE_DIR/a.txt" --metodo prefijo --prefijo C_ --modo copiar --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_file "$CASE_DIR/C_a.txt" || return 1
  printf user > "$CASE_DIR/C_a.txt"
  local undo_output
  undo_output=$(printf '1\n\n' | (export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en; source "$SCRIPT"; deshacer_ultimo) 2>&1)
  assert_file "$CASE_DIR/C_a.txt" || return 1
  assert_content "$CASE_DIR/C_a.txt" 'user' || return 1
  assert_contains "$undo_output" 'Failures: 1' || return 1
}

risky_history_move_undo_test() {
  new_case
  printf original > "$CASE_DIR/a.txt"
  capture_cli en --archivo "$CASE_DIR/a.txt" --metodo prefijo --prefijo M_ --modo mover --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  printf user > "$CASE_DIR/M_a.txt"
  local undo_output
  undo_output=$(printf '1\n\n' | (export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en; source "$SCRIPT"; deshacer_ultimo) 2>&1)
  [[ ! -e "$CASE_DIR/a.txt" ]] || return 1
  assert_content "$CASE_DIR/M_a.txt" 'user' || return 1
  assert_contains "$undo_output" 'Failures: 1' || return 1
  [[ -n "$(find "$CASE_HOME/.config/renombrador/historial" -type f -name '*.log' -print -quit)" ]] || return 1
}

history_legacy_refusal_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  printf legacy > "$CASE_DIR/old-name.txt"
  local token_new token_old
  token_new=$(codificar_texto "$CASE_DIR/new-name.txt")
  token_old=$(codificar_texto "$CASE_DIR/old-name.txt")
  printf '#version:2\n#modo:mover\n%s\t%s\n' "$token_new" "$token_old" > "$HISTORY_DIR/20200101_000000_1.log"
  local undo_output rc
  set +e
  undo_output=$(printf '1\n\n' | deshacer_ultimo 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || return 1
  assert_file "$CASE_DIR/old-name.txt" || return 1
  assert_contains "$undo_output" 'cannot be safely undone' || return 1
  assert_file "$HISTORY_DIR/20200101_000000_1.log" || return 1

  printf '%s%s%s\n' "$CASE_DIR/old-name.txt" "$LOG_SEP" "$CASE_DIR/new-name.txt" > "$HISTORY_DIR/20190101_000000_1.log"
  undo_output=$(printf '2\n\n' | deshacer_ultimo 2>&1)
  assert_contains "$undo_output" 'cannot be safely undone' || return 1
  assert_file "$HISTORY_DIR/20190101_000000_1.log" || return 1
}

history_malformed_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  printf original > "$CASE_DIR/a.txt"
  local token
  token=$(codificar_texto "$CASE_DIR/a.txt")
  printf '#version:3\n#modo:copiar\nC\t%s\t-\tINVALID\n' "$token" > "$HISTORY_DIR/20210101_000000_1.log"
  local undo_output rc
  set +e
  undo_output=$(printf '1\n\n' | deshacer_ultimo 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || return 1
  assert_file "$CASE_DIR/a.txt" || return 1
  assert_contains "$undo_output" 'history is corrupted' || return 1
}

history_nested_undo_test() {
  new_case
  mkdir "$CASE_DIR/sub"
  printf x > "$CASE_DIR/sub/a.txt"
  capture_cli en --carpeta "$CASE_DIR" --recursivo --incluir-carpetas --metodo prefijo --prefijo Z_ --modo mover --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_file "$CASE_DIR/Z_sub/Z_a.txt" || return 1
  local undo_output
  undo_output=$(printf '1\n\n' | (export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en; source "$SCRIPT"; deshacer_ultimo) 2>&1)
  assert_file "$CASE_DIR/sub/a.txt" || return 1
  assert_absent "$CASE_DIR/Z_sub" || return 1
  assert_contains "$undo_output" 'Reverted: 2' || return 1
  [[ -z "$(find "$CASE_HOME/.config/renombrador/historial" -type f -name '*.log' -print -quit)" ]] || return 1
}

date_transformation_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  printf x > "$CASE_DIR/photo.jpg"
  touch -d '2020-01-02 03:04:05' "$CASE_DIR/photo.jpg"
  FILES=("$CASE_DIR/photo.jpg")
  NOMBRES_COLA=('photo.jpg')
  transformar_fecha 2 1
  [[ "${NOMBRES_COLA[0]}" == '2020-01-02_photo.jpg' ]] || return 1
  NOMBRES_COLA=('photo.jpg')
  transformar_fecha 2 2
  [[ "${NOMBRES_COLA[0]}" == 'photo_2020-01-02.jpg' ]] || return 1
}

cli_help_version_test() {
  new_case
  local ver
  ver=$(sed -n 's/^VERSION="\([0-9][0-9.]*\)"$/\1/p' "$SCRIPT" | head -n1)
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  capture_cli en --version
  (( CLI_RC == 0 )) || return 1
  [[ "$CLI_OUTPUT" == "Renombrador $ver" ]] || return 1

  capture_cli en --help
  (( CLI_RC == 0 )) || return 1
  assert_contains "$CLI_OUTPUT" '--carpeta PATH' || return 1
  assert_contains "$CLI_OUTPUT" '--dry-run' || return 1

  capture_cli es --lang es --help
  (( CLI_RC == 0 )) || return 1
  assert_contains "$CLI_OUTPUT" 'Uso:' || return 1
  assert_contains "$CLI_OUTPUT" '--carpeta RUTA' || return 1
}

cli_help_no_storage_test() {
  new_case
  local args a rc
  for args in "--help" "--version" "--lang en --help" "--lang es --version"; do
    read -ra a <<< "$args"
    capture_cli en "${a[@]}"
    (( CLI_RC == 0 )) || return 1
    assert_absent "$CASE_HOME/.config" || return 1
  done
  chmod 500 "$CASE_HOME"
  capture_cli en --help
  rc=$CLI_RC
  chmod 700 "$CASE_HOME"
  (( rc == 0 )) || return 1
  # A value that merely looks like --help is not a help request.
  printf a > "$CASE_DIR/a.txt"
  capture_cli en --archivo "$CASE_DIR/a.txt" --metodo prefijo --prefijo --help --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_file "$CASE_DIR/--helpa.txt" || return 1
  [[ -d "$CASE_HOME/.config/renombrador/historial" ]] || return 1
}

cli_exit_code_partial_failure_test() {
  new_case
  printf a > "$CASE_DIR/a.txt"; printf b > "$CASE_DIR/b.txt"
  mkdir -p "$CASE_DIR/bin"
  cat > "$CASE_DIR/bin/mv" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do [[ "$arg" == */b.txt ]] && exit 1; done
exec /usr/bin/mv "$@"
EOF
  chmod +x "$CASE_DIR/bin/mv"
  local out rc
  out=$( (export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en PATH="$CASE_DIR/bin:$PATH"
          bash "$SCRIPT" --archivo "$CASE_DIR/a.txt" --archivo "$CASE_DIR/b.txt" \
            --metodo prefijo --prefijo X_ --sin-confirmar) 2>&1 )
  rc=$?
  (( rc == 1 )) || return 1
  assert_contains "$out" 'Failures: 1' || return 1
  assert_file "$CASE_DIR/X_a.txt" || return 1
  assert_file "$CASE_DIR/b.txt" || return 1
}

cli_validation_test() {
  new_case
  capture_cli en --lang xx --version
  (( CLI_RC == 2 )) || return 1
  assert_contains "$CLI_OUTPUT" 'Invalid --lang value' || return 1

  capture_cli en --metodo prefijo --prefijo X_
  (( CLI_RC == 1 )) || return 1
  assert_contains "$CLI_OUTPUT" 'Missing source' || return 1

  capture_cli en --archivo "$CASE_DIR/missing.txt" --metodo prefijo --prefijo X_
  (( CLI_RC == 1 )) || return 1
  assert_contains "$CLI_OUTPUT" 'No items were found' || return 1

  capture_cli en --archivo "$CASE_DIR/one.txt" --archivo "$CASE_DIR/two.txt" --carpeta "$CASE_DIR" --metodo prefijo --prefijo X_ --dry-run
  (( CLI_RC == 1 )) || return 1
  assert_contains "$CLI_OUTPUT" 'not both' || return 1
}

cli_folder_selection_test() {
  new_case
  mkdir -p "$CASE_DIR/sub/deep" "$CASE_DIR/.hidden-dir"
  printf x > "$CASE_DIR/a.jpg"
  printf x > "$CASE_DIR/b.txt"
  printf x > "$CASE_DIR/.hidden.txt"
  printf x > "$CASE_DIR/sub/c.jpg"
  printf x > "$CASE_DIR/sub/deep/d.png"
  printf x > "$CASE_DIR/.hidden-dir/e.jpg"

  capture_cli en --carpeta "$CASE_DIR" --metodo prefijo --prefijo X_ --dry-run
  (( CLI_RC == 0 )) || return 1
  assert_contains "$CLI_OUTPUT" '2 item(s) found' || return 1
  assert_contains "$CLI_OUTPUT" 'a.jpg' || return 1
  assert_contains "$CLI_OUTPUT" 'b.txt' || return 1

  capture_cli en --carpeta "$CASE_DIR" --recursivo --filtro jpg,png --metodo prefijo --prefijo X_ --dry-run
  (( CLI_RC == 0 )) || return 1
  assert_contains "$CLI_OUTPUT" '3 item(s) found' || return 1
  assert_contains "$CLI_OUTPUT" 'a.jpg' || return 1
  assert_contains "$CLI_OUTPUT" 'c.jpg' || return 1
  assert_contains "$CLI_OUTPUT" 'd.png' || return 1

  capture_cli en --carpeta "$CASE_DIR" --recursivo --ocultos --filtro jpg --metodo prefijo --prefijo X_ --dry-run
  (( CLI_RC == 0 )) || return 1
  assert_contains "$CLI_OUTPUT" '3 item(s) found' || return 1
  assert_contains "$CLI_OUTPUT" 'e.jpg' || return 1

  capture_cli en --carpeta "$CASE_DIR" --recursivo --incluir-carpetas --metodo prefijo --prefijo X_ --dry-run
  (( CLI_RC == 0 )) || return 1
  assert_contains "$CLI_OUTPUT" '6 item(s) found' || return 1
  assert_contains "$CLI_OUTPUT" 'sub' || return 1
  assert_contains "$CLI_OUTPUT" 'deep' || return 1
}

interactive_yes_alias_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  mkdir -p "$CASE_DIR/sub"
  printf x > "$CASE_DIR/visible.txt"
  printf x > "$CASE_DIR/.hidden.txt"
  printf x > "$CASE_DIR/sub/nested.txt"
  SELECTOR=zenity
  local bin input out word
  bin=$(mktemp -d "$TMP/bin.XXXXXX")
  cat > "$bin/zenity" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$CASE_DIR'
EOF
  chmod +x "$bin/zenity"
  export PATH="$bin:$PATH"
  input=$(mktemp "$TMP/in.XXXXXX")
  printf 'y\ny\nn\nn\n\n0\n' > "$input"
  out=$(opcion_carpeta < "$input" 2>&1)
  assert_contains "$out" 'Found 3 item(s).' || return 1
  # Whole words count too: "yes", "si" and "sí" are not "n".
  for word in yes SI Sí; do
    printf '%s\n%s\nn\nn\n\n0\n' "$word" "$word" > "$input"
    out=$(opcion_carpeta < "$input" 2>&1)
    assert_contains "$out" 'Found 3 item(s).' || return 1
  done
  printf 'no\nsip\nn\nn\n\n0\n' > "$input"
  out=$(opcion_carpeta < "$input" 2>&1)
  assert_contains "$out" 'Found 1 item(s).' || return 1
}

interactive_pattern_start_decimal_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  printf x > "$CASE_DIR/photo.jpg"
  FILES=("$CASE_DIR/photo.jpg")
  NOMBRES_COLA=('photo.jpg')
  local input out
  input=$(mktemp "$TMP/in.XXXXXX")
  out=$(mktemp "$TMP/out.XXXXXX")
  # {n}'s own prompt (pedir_parametros_n) must get the same decimal guard as
  # --inicio: "08" is invalid octal but valid decimal 8.
  printf '{n}_{name}.{ext}\n08\n\n' > "$input"
  aplicar_patron_puntual < "$input" > "$out" 2>&1
  [[ "${NOMBRES_COLA[0]}" == '8_photo.jpg' ]] || return 1
  [[ "$(cat "$out")" != *'too great for base'* ]] || return 1
}

# A closed/exhausted stdin must not spin a menu loop forever. Each test below
# runs the loop under `timeout` and asserts on both the exit status (124 means
# it was killed still running) and the output size (a spinning loop prints
# thousands of lines in seconds; a clean exit prints one or two menu screens).
menu_metodos_eof_test() {
  new_case
  printf x > "$CASE_DIR/a.txt"
  local out rc lines
  out=$(mktemp "$TMP/out.XXXXXX")
  printf '2\nPRE_\n' | HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en \
    timeout 3 bash -c 'source "$1"; FILES=("$2/a.txt"); menu_metodos' _ "$SCRIPT" "$CASE_DIR" \
    > "$out" 2>&1
  rc=$?
  (( rc != 124 )) || { cat "$out" >&2; return 1; }
  lines=$(wc -l < "$out")
  (( lines < 100 )) || { printf 'menu_metodos spun on EOF (%s lines)\n' "$lines" >&2; return 1; }
  assert_file "$CASE_DIR/a.txt" || return 1
  assert_absent "$CASE_DIR/PRE_a.txt" || return 1
}

gestionar_plantillas_eof_test() {
  new_case
  local out rc lines
  out=$(mktemp "$TMP/out.XXXXXX")
  HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en \
    timeout 3 bash -c 'source "$1"; gestionar_plantillas' _ "$SCRIPT" \
    < /dev/null > "$out" 2>&1
  rc=$?
  (( rc != 124 )) || { cat "$out" >&2; return 1; }
  lines=$(wc -l < "$out")
  (( lines < 100 )) || { printf 'gestionar_plantillas spun on EOF (%s lines)\n' "$lines" >&2; return 1; }
}

main_menu_eof_test() {
  new_case
  local bin out rc lines
  bin=$(mktemp -d "$TMP/bin.XXXXXX")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/zenity"
  chmod +x "$bin/zenity"
  out=$(mktemp "$TMP/out.XXXXXX")
  PATH="$bin:$PATH" HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en \
    timeout 3 bash "$SCRIPT" < /dev/null > "$out" 2>&1
  rc=$?
  (( rc == 0 )) || { cat "$out" >&2; return 1; }
  lines=$(wc -l < "$out")
  (( lines < 100 )) || { printf 'main menu spun on EOF (%s lines)\n' "$lines" >&2; return 1; }
}

cli_method_dispatch_smoke_test() {
  new_case
  printf 'Hello World.TXT' > "$CASE_DIR/a.TXT"

  capture_cli en --archivo "$CASE_DIR/a.TXT" --metodo sufijo --sufijo _x --dry-run --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_contains "$CLI_OUTPUT" 'a_x.TXT' || return 1

  capture_cli en --archivo "$CASE_DIR/a.TXT" --metodo mayus-minus --caso minusculas --dry-run --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_contains "$CLI_OUTPUT" 'a.txt' || return 1

  capture_cli en --archivo "$CASE_DIR/a.TXT" --metodo fecha --fecha-origen modificacion --fecha-pos final --dry-run --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_contains "$CLI_OUTPUT" 'a_20' || return 1

  printf 'clean' > "$CASE_DIR/Hello World.TXT"
  capture_cli en --archivo "$CASE_DIR/Hello World.TXT" --metodo limpiar --espacios guion --dry-run --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_contains "$CLI_OUTPUT" 'Hello-World.TXT' || return 1

  capture_cli en --archivo "$CASE_DIR/a.TXT" --metodo tipo --dry-run --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_contains "$CLI_OUTPUT" 'Documento_001.TXT' || return 1
}

cli_move_copy_dryrun_test() {
  new_case
  printf 'alpha' > "$CASE_DIR/a.txt"
  capture_cli en --archivo "$CASE_DIR/a.txt" --metodo prefijo --prefijo X_ --modo mover --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_file "$CASE_DIR/X_a.txt" || return 1
  assert_absent "$CASE_DIR/a.txt" || return 1

  local history
  history=$(find "$CASE_HOME/.config/renombrador/historial" -type f -name '*.log' -print -quit)
  assert_file "$history" || return 1
  grep -Fqx '#version:3' "$history" || return 1
  grep -Fqx '#modo:mover' "$history" || return 1

  new_case
  printf 'copy' > "$CASE_DIR/a.txt"
  capture_cli en --archivo "$CASE_DIR/a.txt" --metodo prefijo --prefijo C_ --modo copiar --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_content "$CASE_DIR/a.txt" 'copy' || return 1
  assert_content "$CASE_DIR/C_a.txt" 'copy' || return 1
  history=$(find "$CASE_HOME/.config/renombrador/historial" -type f -name '*.log' -print -quit)
  grep -Fqx '#modo:copiar' "$history" || return 1

  new_case
  printf 'dry' > "$CASE_DIR/a.txt"
  capture_cli en --archivo "$CASE_DIR/a.txt" --metodo prefijo --prefijo D_ --dry-run --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_file "$CASE_DIR/a.txt" || return 1
  assert_absent "$CASE_DIR/D_a.txt" || return 1
  assert_contains "$CLI_OUTPUT" 'Preview only' || return 1
}

cli_conflict_policies_test() {
  local policy
  for policy in sufijo sobrescribir omitir; do
    new_case
    printf 'old' > "$CASE_DIR/target.txt"
    printf 'src' > "$CASE_DIR/a.txt"
    capture_cli en --archivo "$CASE_DIR/a.txt" --metodo patron --patron 'target.{ext}' --conflicto "$policy" --sin-confirmar
    (( CLI_RC == 0 )) || return 1
    case "$policy" in
      sufijo)
        assert_file "$CASE_DIR/target.txt" || return 1
        assert_file "$CASE_DIR/target(1).txt" || return 1
        assert_absent "$CASE_DIR/a.txt" || return 1
        assert_content "$CASE_DIR/target(1).txt" 'src' || return 1
        ;;
      sobrescribir)
        assert_file "$CASE_DIR/target.txt" || return 1
        assert_absent "$CASE_DIR/a.txt" || return 1
        assert_content "$CASE_DIR/target.txt" 'src' || return 1
        [[ -z "$(find "$CASE_DIR" -maxdepth 1 -name '.renombrador_backup_*' -print -quit)" ]] || return 1
        ;;
      omitir)
        assert_file "$CASE_DIR/target.txt" || return 1
        assert_file "$CASE_DIR/a.txt" || return 1
        assert_content "$CASE_DIR/target.txt" 'old' || return 1
        assert_contains "$CLI_OUTPUT" 'Skipped: 1' || return 1
        ;;
    esac
  done
  return 0
}

cli_collision_test() {
  new_case
  printf 'a' > "$CASE_DIR/a.txt"
  printf 'b' > "$CASE_DIR/b.txt"
  capture_cli en --archivo "$CASE_DIR/a.txt" --archivo "$CASE_DIR/b.txt" --metodo buscar-reemplazar --buscar '^[ab]' --reemplazar 'same' --regex --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_file "$CASE_DIR/same.txt" || return 1
  assert_file "$CASE_DIR/same(1).txt" || return 1
  assert_absent "$CASE_DIR/a.txt" || return 1
  assert_absent "$CASE_DIR/b.txt" || return 1
  assert_contains "$CLI_OUTPUT" 'collision' || return 1
}

cli_numbering_order_test() {
  new_case
  printf old > "$CASE_DIR/old.txt"
  printf new > "$CASE_DIR/new.txt"
  touch -d '2020-01-01 12:00:00' "$CASE_DIR/old.txt"
  touch -d '2020-01-02 12:00:00' "$CASE_DIR/new.txt"
  capture_cli en --archivo "$CASE_DIR/new.txt" --archivo "$CASE_DIR/old.txt" --metodo numeracion --base doc --inicio 1 --digitos 1 --orden fecha --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_file "$CASE_DIR/doc_1.txt" || return 1
  assert_file "$CASE_DIR/doc_2.txt" || return 1
  assert_content "$CASE_DIR/doc_1.txt" 'old' || return 1
  assert_content "$CASE_DIR/doc_2.txt" 'new' || return 1
}

cli_template_test() {
  new_case
  mkdir -p "$CASE_HOME/.config/renombrador"
  printf 'Docs|P_{n}_{name}.{ext}\n' > "$CASE_HOME/.config/renombrador/plantillas.conf"
  printf 'x' > "$CASE_DIR/readme.txt"
  capture_cli en --archivo "$CASE_DIR/readme.txt" --metodo plantilla --plantilla Docs --inicio 5 --digitos 2 --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_file "$CASE_DIR/P_05_readme.txt" || return 1
  assert_absent "$CASE_DIR/readme.txt" || return 1

  new_case
  printf 'x' > "$CASE_DIR/readme.txt"
  capture_cli en --archivo "$CASE_DIR/readme.txt" --metodo plantilla --plantilla Missing --sin-confirmar
  (( CLI_RC == 1 )) || return 1
  assert_contains "$CLI_OUTPUT" 'does not exist' || return 1
}

example_templates_test() {
  local spec file lang name pat extra rest toks idx w
  local -a first=()
  for spec in plantillas-ejemplo.es.conf:es example-templates.en.conf:en; do
    file="$ROOT_DIR/assets/templates/${spec%:*}"; lang="${spec#*:}"
    new_case
    [[ "$(wc -l < "$file")" -eq 16 ]] || return 1
    mkdir -p "$CASE_HOME/.config/renombrador"
    cp -- "$file" "$CASE_HOME/.config/renombrador/plantillas.conf"
    printf x > "$CASE_DIR/doc.txt"
    local -A seen=() pats=()
    idx=0
    while IFS='|' read -r -u 3 name pat extra; do
      [[ -n "$name" && -n "$pat" && -z "$extra" && -z "${seen[$name]:-}" && -z "${pats[$pat]:-}" ]] || return 1
      seen[$name]=1; pats[$pat]=1
      rest="$pat"; toks=''
      while [[ "$rest" =~ \{([a-z]+)\} ]]; do
        toks+="${BASH_REMATCH[1]},"; rest="${rest#*"${BASH_REMATCH[0]}"}"
      done
      rest="$pat"
      for w in name ext n date parent filedate filetime; do rest="${rest//\{"$w"\}/}"; done
      [[ "$rest" =~ ^[A-Za-z0-9_.-]*$ ]] || return 1
      [[ "$pat" != [-.]* ]] || return 1
      if [[ "$lang" == es ]]; then first[idx]="$toks"; else [[ "${first[idx]:-}" == "$toks" ]] || return 1; fi
      capture_cli "$lang" --archivo "$CASE_DIR/doc.txt" --metodo plantilla --plantilla "$name" --dry-run
      (( CLI_RC == 0 )) || return 1
      idx=$((idx + 1))
    done 3< "$file"
    (( idx == 16 )) || return 1
  done
}

# {filedate}/{filetime} come from each file's own mtime (EXIF for photos): the two
# bundled timestamp templates must sort chronologically and never overwrite.
example_timestamp_templates_test() {
  local lang file tl ev dir burst
  for lang in es en; do
    if [[ "$lang" == es ]]; then file="$ROOT_DIR/assets/templates/plantillas-ejemplo.es.conf"
    else file="$ROOT_DIR/assets/templates/example-templates.en.conf"; fi
    tl=$(awk -F'|' '$2 == "{filedate}_{filetime}_{name}" {print $1}' "$file")
    ev=$(awk -F'|' '$2 == "{parent}_{filedate}_{filetime}" {print $1}' "$file")
    [[ -n "$tl" && -n "$ev" ]] || return 1
    new_case
    dir="$CASE_DIR/Trip"; burst="$CASE_DIR/Burst"
    mkdir -p "$dir" "$burst" "$CASE_HOME/.config/renombrador"
    cp -- "$file" "$CASE_HOME/.config/renombrador/plantillas.conf"
    printf c > "$dir/z_old.txt"; touch -d '2020-03-01 08:00:01' "$dir/z_old.txt"
    printf b > "$dir/m_mid.txt"; touch -d '2021-06-15 12:30:45' "$dir/m_mid.txt"
    printf a > "$dir/a_new.txt"; touch -d '2022-12-31 23:59:58' "$dir/a_new.txt"
    printf n > "$dir/README";    touch -d '2019-01-02 03:04:05' "$dir/README"

    capture_cli "$lang" --carpeta "$dir" --metodo plantilla --plantilla "$tl" --sin-confirmar
    (( CLI_RC == 0 )) || return 1
    assert_content "$dir/2020-03-01_08-00-01_z_old.txt" c || return 1
    assert_content "$dir/2021-06-15_12-30-45_m_mid.txt" b || return 1
    assert_content "$dir/2022-12-31_23-59-58_a_new.txt" a || return 1
    assert_content "$dir/2019-01-02_03-04-05_README" n || return 1
    [[ "$(cd "$dir" && LC_ALL=C; printf '%s ' *)" == '2019-01-02_03-04-05_README 2020-03-01_08-00-01_z_old.txt 2021-06-15_12-30-45_m_mid.txt 2022-12-31_23-59-58_a_new.txt ' ]] || return 1

    capture_cli "$lang" --carpeta "$dir" --metodo plantilla --plantilla "$ev" --sin-confirmar
    (( CLI_RC == 0 )) || return 1
    assert_content "$dir/Trip_2020-03-01_08-00-01.txt" c || return 1
    assert_content "$dir/Trip_2019-01-02_03-04-05" n || return 1
    assert_absent "$dir/2020-03-01_08-00-01_z_old.txt" || return 1

    printf 1 > "$burst/a.txt"; printf 2 > "$burst/b.txt"
    touch -d '2024-05-06 07:08:09' "$burst/a.txt" "$burst/b.txt"
    capture_cli "$lang" --carpeta "$burst" --metodo plantilla --plantilla "$ev" --sin-confirmar
    (( CLI_RC == 0 )) || return 1
    assert_content "$burst/Burst_2024-05-06_07-08-09.txt" 1 || return 1
    assert_content "$burst/Burst_2024-05-06_07-08-09(1).txt" 2 || return 1
  done
}

# Photo dates are read in batches: one exiftool call per EXIF_LOTE photos, not one
# per file. The stub reads "DateTimeOriginal|CreateDate" from each file's content
# and logs every call; files named *skip.jpg are omitted in batch mode only. Like
# the real exiftool, it prints "$Directory/$FileName": "//" collapsed, "./" if bare.
exif_batch_cache_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en EXIF_LOG="$CASE_DIR/exif.log"
  local pics="$CASE_DIR/pics" nl k
  mkdir -p "$CASE_DIR/bin" "$pics"
  cat > "$CASE_DIR/bin/exiftool" <<'EOF'
#!/usr/bin/env bash
mode=single
while (( $# )); do
  case "$1" in -p) mode=batch ;; --) shift; break ;; esac
  shift
done
printf '%s %d\n' "$mode" "$#" >> "$EXIF_LOG"
for f in "$@"; do
  [[ -f "$f" ]] || continue
  dto=''; create=''
  IFS='|' read -r dto create < "$f" || true
  if [[ "$mode" == batch ]]; then
    [[ "$f" == *skip.jpg ]] && continue
    d=.; [[ "$f" == */* ]] && d=${f%/*}
    while [[ "$d" == */ ]]; do d=${d%/}; done
    printf '%s\t%s\t%s/%s\n' "${dto:--}" "${create:--}" "${d:-/}" "${f##*/}"
  else
    [[ -n "$dto" ]] && printf '%s\n' "$dto"
    [[ -n "$create" ]] && printf '%s\n' "$create"
  fi
done
EOF
  chmod +x "$CASE_DIR/bin/exiftool"
  export PATH="$CASE_DIR/bin:$PATH"

  printf '2021:03:04 05:06:07|' > "$pics/a.jpg"
  printf '|2019:12:31 23:59:58' > "$pics/Año [2].jpg"
  printf '|' > "$pics/none.jpg";   touch -d '2015-01-02 03:04:05' "$pics/none.jpg"
  printf '0000:00:00 00:00:00|' > "$pics/zero.jpg"; touch -d '2016-05-06 07:08:09' "$pics/zero.jpg"
  printf '2018:08:09 10:11:12|' > "$pics/skip.jpg"
  printf '2001:01:01 01:01:01|' > "$pics/note.txt"; touch -d '2014-07-08 09:10:11' "$pics/note.txt"
  cp -a "$pics" "$CASE_DIR/pics2"

  capture_cli en --carpeta "$pics" --metodo patron --patron '{filedate}_{filetime}_{name}' --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_file "$pics/2021-03-04_05-06-07_a.jpg" || return 1
  assert_file "$pics/2019-12-31_23-59-58_Año [2].jpg" || return 1
  assert_file "$pics/2015-01-02_03-04-05_none.jpg" || return 1
  assert_file "$pics/2016-05-06_07-08-09_zero.jpg" || return 1
  assert_file "$pics/2018-08-09_10-11-12_skip.jpg" || return 1
  assert_file "$pics/2014-07-08_09-10-11_note.txt" || return 1
  [[ "$(<"$EXIF_LOG")" == $'batch 5\nsingle 1' ]] || return 1

  : > "$EXIF_LOG"
  capture_cli en --carpeta "$CASE_DIR/pics2/" --metodo patron --patron '{filedate}_{filetime}_{name}' --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_file "$CASE_DIR/pics2/2019-12-31_23-59-58_Año [2].jpg" || return 1
  [[ "$(<"$EXIF_LOG")" == $'batch 5\nsingle 1' ]] || return 1

  source "$SCRIPT"
  exif_clave k '//a//b///c.jpg'; [[ "$k" == /a/b/c.jpg ]] || return 1
  exif_clave k c.jpg; [[ "$k" == ./c.jpg ]] || return 1
  export EXIF_LOTE=2
  FILES=("$pics/2021-03-04_05-06-07_a.jpg" "$pics/2015-01-02_03-04-05_none.jpg" "$pics/2016-05-06_07-08-09_zero.jpg" "$pics/2018-08-09_10-11-12_skip.jpg" "$pics/2019-12-31_23-59-58_Año [2].jpg" "$pics/2014-07-08_09-10-11_note.txt")
  : > "$EXIF_LOG"
  precargar_exif
  [[ "$(<"$EXIF_LOG")" == $'batch 2\nbatch 2\nbatch 1' ]] || return 1
  [[ "${#EXIF_CACHE[@]}" -eq 4 ]] || return 1
  k="$pics/2019-12-31_23-59-58_Año [2].jpg"
  [[ "${EXIF_CACHE[$k]}" == '2019-12-31 23:59:58' ]] || return 1
  k="$pics/2015-01-02_03-04-05_none.jpg"
  [[ -n "${EXIF_CACHE[$k]+x}" && -z "${EXIF_CACHE[$k]}" ]] || return 1
  k="$pics/2018-08-09_10-11-12_skip.jpg"
  [[ -z "${EXIF_CACHE[$k]+x}" ]] || return 1
  : > "$EXIF_LOG"
  [[ "$(fecha_exif_raw "$pics/2021-03-04_05-06-07_a.jpg")" == '2021-03-04 05:06:07' ]] || return 1
  [[ ! -s "$EXIF_LOG" ]] || return 1
  [[ "$(fecha_exif_raw "$k")" == '2018-08-09 10:11:12' ]] || return 1
  [[ "$(<"$EXIF_LOG")" == 'single 1' ]] || return 1

  nl="$pics/nl"$'\n'"x.jpg"
  printf '2020:02:02 02:02:02|' > "$nl"
  FILES=("$pics/2021-03-04_05-06-07_a.jpg" "$nl")
  : > "$EXIF_LOG"
  precargar_exif
  [[ "${#EXIF_CACHE[@]}" -eq 1 && "$(<"$EXIF_LOG")" == 'batch 1' ]] || return 1
  [[ "$(fecha_exif_raw "$nl")" == '2020-02-02 02:02:02' ]] || return 1

  export EXIFTOOL_DISPONIBLE='' IDENTIFY_DISPONIBLE='' EXIF_CHEQUEADO=1
  : > "$EXIF_LOG"
  precargar_exif
  [[ "${#EXIF_CACHE[@]}" -eq 0 && ! -s "$EXIF_LOG" ]] || return 1
}

cli_nested_directory_test() {
  new_case
  mkdir "$CASE_DIR/sub"
  printf x > "$CASE_DIR/sub/a.txt"
  capture_cli en --carpeta "$CASE_DIR" --recursivo --incluir-carpetas --metodo prefijo --prefijo Z_ --modo mover --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_file "$CASE_DIR/Z_sub" || return 1
  assert_file "$CASE_DIR/Z_sub/Z_a.txt" || return 1
  assert_absent "$CASE_DIR/sub" || return 1

  new_case
  mkdir "$CASE_DIR/sub"
  printf x > "$CASE_DIR/sub/a.txt"
  capture_cli en --carpeta "$CASE_DIR" --recursivo --incluir-carpetas --metodo prefijo --prefijo Z_ --modo copiar --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_file "$CASE_DIR/sub/a.txt" || return 1
  assert_file "$CASE_DIR/Z_sub/a.txt" || return 1
  assert_file "$CASE_DIR/sub/Z_a.txt" || return 1
}

history_nested_copy_undo_test() {
  new_case
  mkdir "$CASE_DIR/sub"
  printf x > "$CASE_DIR/sub/a.txt"
  capture_cli en --carpeta "$CASE_DIR" --recursivo --incluir-carpetas --metodo prefijo --prefijo Z_ --modo copiar --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_file "$CASE_DIR/Z_sub/a.txt" || return 1
  assert_file "$CASE_DIR/sub/Z_a.txt" || return 1
  local undo_output="$TMP/undo-nested-copy-output.txt"
  printf '1\n\n' | (
    export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
    source "$SCRIPT"
    deshacer_ultimo
  ) >"$undo_output" 2>&1
  local rc=$?
  [[ "$rc" -eq 0 ]] || return 1
  assert_file "$CASE_DIR/sub/a.txt" || return 1
  assert_absent "$CASE_DIR/Z_sub" || return 1
  assert_absent "$CASE_DIR/sub/Z_a.txt" || return 1
  assert_contains "$(cat -- "$undo_output")" 'Copies deleted: 2' || return 1
}

cli_edge_cases_test() {
  new_case
  mkdir "$CASE_DIR/sub"
  capture_cli en --archivo "$CASE_DIR/sub/" --metodo prefijo --prefijo X_ --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_file "$CASE_DIR/X_sub" || return 1
  assert_absent "$CASE_DIR/sub" || return 1

  capture_cli en --carpeta / --metodo prefijo --prefijo X_ --dry-run --sin-confirmar
  (( CLI_RC == 1 )) || return 1
  assert_contains "$CLI_OUTPUT" 'cannot be processed safely' || return 1

  capture_cli en --archivo / --metodo prefijo --prefijo X_ --dry-run --sin-confirmar
  (( CLI_RC == 1 )) || return 1
  assert_contains "$CLI_OUTPUT" 'cannot be processed safely' || return 1

  printf x > "$CASE_DIR/x.txt"
  capture_cli en --archivo "$CASE_DIR/x.txt" --metodo numeracion --base x --inicio invalid --dry-run --sin-confirmar
  (( CLI_RC == 1 )) || return 1
  assert_contains "$CLI_OUTPUT" 'Invalid --inicio value' || return 1

  capture_cli en --archivo "$CASE_DIR/x.txt" --metodo numeracion --base x --inicio 9000000000000000001 --dry-run --sin-confirmar
  (( CLI_RC == 1 )) || return 1
  assert_contains "$CLI_OUTPUT" 'Invalid --inicio value' || return 1

  capture_cli en --archivo "$CASE_DIR/x.txt" --metodo numeracion --base x --digitos 19 --dry-run --sin-confirmar
  (( CLI_RC == 1 )) || return 1
  assert_contains "$CLI_OUTPUT" 'Invalid --digitos value' || return 1

  # --inicio/--digitos must be read as decimal, never as octal (leading zero).
  capture_cli en --archivo "$CASE_DIR/x.txt" --metodo numeracion --base x --inicio 010 --digitos 3 --dry-run --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_contains "$CLI_OUTPUT" 'x_010.txt' || return 1

  # "08" is invalid octal (digit 8) but valid decimal 8: must not raise a raw
  # bash arithmetic error, and must resolve to decimal 8.
  capture_cli en --archivo "$CASE_DIR/x.txt" --metodo numeracion --base x --inicio 08 --dry-run --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_contains "$CLI_OUTPUT" 'x_8.txt' || return 1
  [[ "$CLI_OUTPUT" != *'too great for base'* ]] || return 1

  # An arbitrarily long --inicio must be rejected cleanly, never overflow.
  capture_cli en --archivo "$CASE_DIR/x.txt" --metodo numeracion --base x --inicio 99999999999999999999999999999999999999 --dry-run --sin-confirmar
  (( CLI_RC == 1 )) || return 1
  assert_contains "$CLI_OUTPUT" 'Invalid --inicio value' || return 1
  [[ "$CLI_OUTPUT" != *'too great for base'* ]] || return 1

  capture_cli en --archivo "$CASE_DIR/x.txt" --metodo numeracion --base x --inicio 9000000000000000000 --digitos 0 --dry-run --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_contains "$CLI_OUTPUT" 'x_9000000000000000000.txt' || return 1
}

symlink_boundary_test() {
  new_case
  mkdir -p "$CASE_DIR/root/real" "$CASE_DIR/outside"
  printf inside > "$CASE_DIR/root/real/a.txt"
  printf outside > "$CASE_DIR/outside/b.txt"
  ln -s "$CASE_DIR/outside/b.txt" "$CASE_DIR/root/external.txt"
  ln -s "$CASE_DIR/root/real/a.txt" "$CASE_DIR/root/internal.txt"

  capture_cli en --carpeta "$CASE_DIR/root" --recursivo --seguir-enlaces --metodo prefijo --prefijo X_ --dry-run --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_contains "$CLI_OUTPUT" '1 item(s) found' || return 1
  [[ "$CLI_OUTPUT" != *'b.txt'* ]] || return 1
  [[ "$CLI_OUTPUT" == *'internal.txt'* || "$CLI_OUTPUT" == *'a.txt'* ]] || return 1
}

history_symlink_filter_test() {
  new_case
  printf original > "$CASE_DIR/a.txt"
  capture_cli en --archivo "$CASE_DIR/a.txt" --metodo prefijo --prefijo H_ --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  local history listing
  history=$(find "$CASE_HOME/.config/renombrador/historial" -maxdepth 1 -type f -name '*.log' -print -quit)
  [[ -n "$history" ]] || return 1
  ln -s "$history" "$CASE_HOME/.config/renombrador/historial/99999999_999999_999.log"

  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  listar_historial > "$CASE_DIR/history-list.txt"
  [[ ${#LOTES[@]} -eq 1 ]] || return 1
  listing=$(cat -- "$CASE_DIR/history-list.txt")
  [[ "$listing" != *'9999-99-99'* ]] || return 1
}

history_trailing_newline_path_test() {
  new_case
  local original newname output="$TMP/undo-newline-output.txt"
  original="$CASE_DIR/original.txt"$'\n'
  newname="$CASE_DIR/P_original.txt"$'\n'
  printf x > "$original"
  capture_cli en --archivo "$original" --metodo prefijo --prefijo P_ --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  [[ -f "$newname" ]] || return 1
  rm -f -- "$original"

  printf '1\n\n' | (
    export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
    source "$SCRIPT"
    deshacer_ultimo
  ) >"$output" 2>&1 || return 1
  [[ -f "$original" ]] || return 1
  [[ ! -e "$newname" ]] || return 1
}

regex_newline_name_test() {
  new_case
  local original renamed cleaned
  original="$CASE_DIR/foo"$'\n'"bar.txt"
  renamed="$CASE_DIR/X"$'\n'"bar.txt"
  printf x > "$original"
  capture_cli en --archivo "$original" --metodo buscar-reemplazar --buscar foo --reemplazar X --regex --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  [[ -f "$renamed" ]] || return 1
  [[ ! -e "$original" ]] || return 1

  cleaned="$CASE_DIR/Hello<>"$'\n'"World.txt"
  printf x > "$cleaned"
  capture_cli en --archivo "$cleaned" --metodo limpiar --espacios guion_bajo --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  [[ -f "$CASE_DIR/Hello"$'\n'"World.txt" ]] || return 1
}

terminal_user_data_safety_test() {
  new_case
  local name="$CASE_DIR/literal\\e[31m.txt" output="$TMP/history-output.txt"
  printf x > "$name"
  capture_cli en --archivo "$name" --metodo prefijo --prefijo X_ --modo mover --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  printf y >> "$CASE_DIR/X_literal\\e[31m.txt"
  printf '1\n\n' | (
    export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
    source "$SCRIPT"
    deshacer_ultimo
  ) >"$output" 2>&1 || return 1
  local text
  text=$(cat -- "$output")
  [[ "$text" != *$'\e'* ]] || return 1
  assert_contains "$text" $'\\e[31m.txt' || return 1
}

terminal_escape_sanitization_test() {
  # A real ESC (and the C1 CSI U+009B) in file, template or history names must
  # never reach the terminal raw: preview, errors, template flows and undo.
  new_case
  local esc=$'\e' c1=$'\xc2\x9b' cfg="$CASE_HOME/.config/renombrador" name out flow fn input want mode
  for name in "a${esc}]0;PWNED${esc}b.txt" "a${c1}31mb.txt"; do
    printf x > "$CASE_DIR/$name"
    capture_cli en --archivo "$CASE_DIR/$name" --metodo prefijo --prefijo X_ --dry-run
    (( CLI_RC == 0 )) || return 1
    no_raw_control "$CLI_OUTPUT" || return 1
    assert_contains "$CLI_OUTPUT" 'a?' || return 1
    capture_cli en --archivo "$CASE_DIR/$name.gone" --metodo prefijo --prefijo X_ --sin-confirmar
    no_raw_control "$CLI_OUTPUT" || return 1
    assert_contains "$CLI_OUTPUT" 'does not exist' || return 1
    capture_cli en --carpeta "$CASE_DIR/$name.dir" --metodo prefijo --prefijo X_ --sin-confirmar
    no_raw_control "$CLI_OUTPUT" || return 1
    assert_contains "$CLI_OUTPUT" 'does not exist' || return 1
    capture_cli en --lang "$name" --version
    (( CLI_RC == 2 )) || return 1
    no_raw_control "$CLI_OUTPUT" || return 1
  done
  # A literal "\033" typed as text must not become a real ESC via echo -e.
  capture_cli en --lang 'x\033[31m' --version
  no_raw_control "$CLI_OUTPUT" || return 1
  assert_contains "$CLI_OUTPUT" 'x\033[31m' || return 1

  mkdir -p "$cfg"
  printf '%s\n' "T${esc}[31m|P${esc}_{n}" "C${c1}|Q${c1}_{n}" > "$cfg/plantillas.conf"
  for flow in 'listar_plantillas||T?[31m' 'usar_plantilla_guardada|1\n\n\n\n|T?[31m' \
    "guardar_plantilla|N${esc}x\\n{n}_{name}\\n\\n|N?x" 'eliminar_plantilla|1\ns\n\n|T?[31m'; do
    IFS='|' read -r fn input want <<< "$flow"
    out=$(printf '%b' "$input" | HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en \
      timeout 10 bash -c 'source "$1"; "$2"' _ "$SCRIPT" "$fn" 2>&1) || return 1
    no_raw_control "$out" || return 1
    assert_contains "$out" "$want" || return 1
  done

  for mode in changed exists; do
    new_case
    printf x > "$CASE_DIR/u${esc}b.txt"
    capture_cli en --archivo "$CASE_DIR/u${esc}b.txt" --metodo prefijo --prefijo X_ --modo mover --sin-confirmar
    (( CLI_RC == 0 )) || return 1
    if [[ "$mode" == changed ]]; then printf y >> "$CASE_DIR/X_u${esc}b.txt"; else printf z > "$CASE_DIR/u${esc}b.txt"; fi
    : > "$CASE_HOME/.config/renombrador/historial/${esc}[31m0123456789.log"
    out=$(printf '1\n\n' | (
      export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
      source "$SCRIPT"
      deshacer_ultimo
    ) 2>&1) || return 1
    no_raw_control "$out" || return 1
    assert_contains "$out" 'X_u?b.txt' || return 1
    assert_contains "$out" '?[31' || return 1
  done
}

atomic_type_safety_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  local target="$CASE_DIR/state" src="$CASE_DIR/source.txt" rc
  mkdir "$target"
  set +e
  printf data | escritura_atomica "$target"
  rc=$?
  set -e
  (( rc != 0 )) || return 1
  [[ -d "$target" ]] || return 1
  printf data > "$src"
  set +e
  copia_item_atomica "$src" "$target"
  rc=$?
  set -e
  (( rc != 0 )) || return 1
  [[ -d "$target" && -f "$src" ]] || return 1
}

history_undo_test() {
  new_case
  printf 'original' > "$CASE_DIR/a.txt"
  capture_cli en --archivo "$CASE_DIR/a.txt" --metodo prefijo --prefijo U_ --modo mover --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_file "$CASE_DIR/U_a.txt" || return 1

  local undo_output="$TMP/undo-output.txt"
  printf '1\n\n' | (
    export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
    source "$SCRIPT"
    deshacer_ultimo
  ) >"$undo_output" 2>&1
  local rc=$?
  [[ "$rc" -eq 0 ]] || { cat "$undo_output" >&2; return 1; }
  assert_file "$CASE_DIR/a.txt" || return 1
  assert_absent "$CASE_DIR/U_a.txt" || return 1
  [[ -z "$(find "$CASE_HOME/.config/renombrador/historial" -type f -name '*.log' -print -quit)" ]] || return 1
}

# A shell function named "mv" takes priority over the real binary for any
# unqualified "mv" call in the sourced script or in a child "bash $SCRIPT"
# (via export -f). Used to emulate a FAT/exFAT mount rejecting names with
# ":*?\"<>|" without needing to actually mount one in CI.
_fake_mv_rejecting_incompatible_chars() {
  mv() {
    local a
    for a in "$@"; do
      case "$a" in
        *[\\:*?\"\<\>\|]*) return 1 ;;
      esac
    done
    command mv "$@"
  }
}

sustituir_caracteres_incompatibles_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  [[ "$(sustituir_caracteres_incompatibles 'a:b*c?d"e<f>g|h')" == 'a_b_c_d_e_f_g_h' ]] || return 1
  [[ "$(sustituir_caracteres_incompatibles 'nombre normal.txt')" == 'nombre normal.txt' ]] || return 1
  [[ "$(sustituir_caracteres_incompatibles 'back\slash.txt')" == 'back_slash.txt' ]] || return 1
  [[ "$(sustituir_caracteres_incompatibles 'año_ñ_中文.txt')" == 'año_ñ_中文.txt' ]] || return 1
}

directorio_solo_lectura_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  local d="$CASE_DIR/ro" rc=0
  mkdir -p "$d"
  directorio_solo_lectura "$d" && rc=1
  if ! chattr +i "$d" 2>/dev/null; then
    skip "directorio_solo_lectura_test (chattr no soportado en este filesystem)"
    return 77
  fi
  directorio_solo_lectura "$d" || rc=1
  chattr -i "$d" 2>/dev/null
  directorio_solo_lectura "$d" && rc=1
  return "$rc"
}

mover_item_incompatible_chars_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  printf 'contenido' > "$CASE_DIR/origen.txt"
  _fake_mv_rejecting_incompatible_chars
  declare -A LIVE=([0]="$CASE_DIR/origen.txt")
  local destino_usado=''
  mover_item 0 "$CASE_DIR/raro:nombre*.txt" destino_usado || return 1
  [[ "$destino_usado" == "$CASE_DIR/raro_nombre_.txt" ]] || return 1
  [[ "${LIVE[0]}" == "$destino_usado" ]] || return 1
  assert_file "$destino_usado" || return 1
  assert_content "$destino_usado" 'contenido' || return 1
  assert_absent "$CASE_DIR/origen.txt" || return 1
}

copia_item_atomica_incompatible_chars_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  printf 'contenido' > "$CASE_DIR/origen2.txt"
  _fake_mv_rejecting_incompatible_chars
  local destino_usado=''
  copia_item_atomica "$CASE_DIR/origen2.txt" "$CASE_DIR/copia:mala*.txt" destino_usado || return 1
  [[ "$destino_usado" == "$CASE_DIR/copia_mala_.txt" ]] || return 1
  assert_file "$destino_usado" || return 1
  assert_content "$destino_usado" 'contenido' || return 1
  assert_file "$CASE_DIR/origen2.txt" || return 1
}

cli_incompatible_chars_retry_test() {
  new_case
  printf 'contenido' > "$CASE_DIR/foto.txt"
  _fake_mv_rejecting_incompatible_chars
  export -f mv
  capture_cli en --archivo "$CASE_DIR/foto.txt" --metodo prefijo --prefijo 'raro:nombre*' --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_file "$CASE_DIR/raro_nombre_foto.txt" || return 1
  assert_absent "$CASE_DIR/foto.txt" || return 1
  assert_content "$CASE_DIR/raro_nombre_foto.txt" 'contenido' || return 1
  assert_contains "$CLI_OUTPUT" 'Failures: 0' || return 1

  local undo_output="$TMP/undo-output-chars.txt"
  printf '1\n\n' | (
    export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
    source "$SCRIPT"
    deshacer_ultimo
  ) >"$undo_output" 2>&1
  local rc=$?
  [[ "$rc" -eq 0 ]] || { cat "$undo_output" >&2; return 1; }
  assert_file "$CASE_DIR/foto.txt" || return 1
  assert_absent "$CASE_DIR/raro_nombre_foto.txt" || return 1
}

cli_readonly_target_preflight_test() {
  new_case
  printf 'x' > "$CASE_DIR/a.txt"
  printf 'y' > "$CASE_DIR/b.txt"
  if ! chattr +i "$CASE_DIR" 2>/dev/null; then
    skip "cli_readonly_target_preflight_test (chattr no soportado en este filesystem)"
    return 77
  fi
  capture_cli en --archivo "$CASE_DIR/a.txt" --archivo "$CASE_DIR/b.txt" --metodo prefijo --prefijo 'N_' --sin-confirmar
  local rc="$CLI_RC" out="$CLI_OUTPUT"
  chattr -i "$CASE_DIR" 2>/dev/null
  (( rc != 0 )) || return 1
  assert_contains "$out" 'Cannot write to' || return 1
  assert_file "$CASE_DIR/a.txt" || return 1
  assert_file "$CASE_DIR/b.txt" || return 1
  assert_absent "$CASE_DIR/N_a.txt" || return 1
  assert_absent "$CASE_DIR/N_b.txt" || return 1
}

numero_en_rango_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  [[ "$(numero_en_rango 1 5)" == 1 && "$(numero_en_rango 05 5)" == 5 ]] || return 1
  local bad
  for bad in 0 00 6 08 18446744073709551617 99999999999999999999 '' a -1 '1 '; do
    numero_en_rango "$bad" 5 >/dev/null 2>"$CASE_DIR/err" && return 1
    [[ ! -s "$CASE_DIR/err" ]] || return 1
  done
}

eliminar_plantilla_race_test() {
  new_case
  local cfg="$CASE_HOME/.config/renombrador" out
  mkdir -p "$cfg"
  printf '%s\n' 'A|a' 'B|b' 'C|c' > "$cfg/plantillas.conf"
  out=$(printf '2\ns\n\n' | HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en \
    bash -c 'source "$1"; eliminar_plantilla' _ "$SCRIPT" 2>&1) || return 1
  assert_contains "$out" 'deleted' || return 1
  assert_content "$cfg/plantillas.conf" $'A|a\nC|c\n' || return 1
  # Another instance rewrites the list after it was shown: the chosen line
  # (now "A|a" at position 2) is not the one confirmed, so nothing is deleted.
  out=$(printf '2\ns\n\n' | HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en \
    bash -c 'source "$1"; bloquear_plantillas() { printf "%s\n" "X|x" "A|a" "C|c" > "$TEMPLATES_FILE"; }; eliminar_plantilla' _ "$SCRIPT" 2>&1) || return 1
  assert_contains "$out" 'changed in the meantime' || return 1
  assert_content "$cfg/plantillas.conf" $'X|x\nA|a\nC|c\n' || return 1
}

# A batch item whose original name was taken by another batch item (a->b,
# b->x with x existing, --conflicto omitir) must stay visible, never hidden
# as .renombrador_tmp_*.
devolver_visible_apply_test() {
  new_case
  printf A > "$CASE_DIR/a"; printf B > "$CASE_DIR/b"; printf X > "$CASE_DIR/x"
  local out
  out=$(HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en bash -c '
    source "$1"; FILES=("$2/a" "$2/b"); NUEVOS=(b x)
    CLI_MODE=1; CLI_MODO=mover; CLI_CONFLICTO=3; CLI_SIN_CONFIRMAR=1
    aplicar_renombrado' _ "$SCRIPT" "$CASE_DIR" 2>&1) || return 1
  assert_contains "$out" 'kept as' || return 1
  assert_content "$CASE_DIR/b" A || return 1
  assert_content "$CASE_DIR/b(1)" B || return 1
  assert_content "$CASE_DIR/x" X || return 1
  [[ -z "$(find "$CASE_DIR" -maxdepth 1 -name '.renombrador_*' -print -quit)" ]] || return 1
}

# Same for undo: the original name of one item is taken again, and its
# post-rename name was reused by another restored item. The item stays
# visible and the pending history entry points to where it is now.
devolver_visible_undo_test() {
  new_case
  printf A > "$CASE_DIR/a"; printf B > "$CASE_DIR/b"
  local out log
  out=$(printf '1\n\n' | HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en bash -c '
    source "$1"; FILES=("$2/b" "$2/a"); NUEVOS=(c b)
    CLI_MODE=1; CLI_MODO=mover; CLI_CONFLICTO=1; CLI_SIN_CONFIRMAR=1
    aplicar_renombrado >/dev/null 2>&1 || exit 1
    printf NEW > "$2/a"; CLI_MODE=0
    deshacer_ultimo' _ "$SCRIPT" "$CASE_DIR" 2>&1) || return 1
  assert_contains "$out" 'kept as' || return 1
  assert_content "$CASE_DIR/a" NEW || return 1
  assert_content "$CASE_DIR/b" B || return 1
  assert_content "$CASE_DIR/b(1)" A || return 1
  [[ -z "$(find "$CASE_DIR" -maxdepth 1 -name '.renombrador_*' -print -quit)" ]] || return 1
  log=$(find "$CASE_HOME/.config/renombrador/historial" -maxdepth 1 -name '*.log' -print -quit)
  [[ -n "$log" ]] || return 1
  grep -Fq "$(printf '%s.' "$CASE_DIR/b(1)" | base64 | tr -d '\n')" "$log" || return 1
}

# Wildcards expand in one pass: a file name containing "{n}" or "{date}"
# stays literal instead of being expanded again.
patron_una_pasada_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  # shellcheck disable=SC2034  # read by the sourced CLI
  FILES=("$CASE_DIR/a{n}b.txt" "$CASE_DIR/c{date}d.txt" "$CASE_DIR/e{x.txt")
  reiniciar_cola
  aplicar_patron '{name}_{n}' 7 3 >/dev/null
  [[ "${NOMBRES_COLA[0]}" == 'a{n}b_007.txt' && "${NOMBRES_COLA[1]}" == 'c{date}d_008.txt' \
    && "${NOMBRES_COLA[2]}" == 'e{x_009.txt' ]]
}

# An exported template file gets the usual mode (0666 & ~umask), not the
# private 0600 of the config copy; an existing destination keeps its own mode.
exportar_plantillas_modo_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  printf 'A|a\n' > "$TEMPLATES_FILE"
  # shellcheck disable=SC2034  # read by the sourced CLI
  SELECTOR=zenity
  umask 022
  zenity() { printf '%s\n' "$CASE_DIR/nuevo.txt"; }
  exportar_plantillas </dev/null >/dev/null 2>&1
  [[ "$(stat -c %a "$CASE_DIR/nuevo.txt")" == 644 ]] || return 1
  printf old > "$CASE_DIR/previo.txt"; chmod 640 "$CASE_DIR/previo.txt"
  zenity() { printf '%s\n' "$CASE_DIR/previo.txt"; }
  exportar_plantillas </dev/null >/dev/null 2>&1
  [[ "$(stat -c %a "$CASE_DIR/previo.txt")" == 640 ]] || return 1
  assert_content "$CASE_DIR/previo.txt" $'A|a\n'
}

cli_help_nemo_flags_test() {
  new_case
  local lang flag
  for lang in es en; do
    capture_cli "$lang" --help
    (( CLI_RC == 0 )) || return 1
    for flag in --instalar-nemo --desinstalar-nemo --activar-nemo --desactivar-nemo; do
      assert_contains "$CLI_OUTPUT" "$flag" || return 1
    done
  done
}

sanear_nuevo_largo_conserva_extension_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  local pref largo largo_ext
  rp() { local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; }

  pref=$(rp a 31); largo=$(rp b 240)
  [[ "$(sanear_nuevo "$pref$largo.jpg")" == "$pref$(rp b 220).jpg" ]] || return 1
  [[ "$(sanear_nuevo "$(rp c 251).png")" == "$(rp c 251).png" ]] || return 1
  [[ "$(sanear_nuevo "$(rp c 252).png")" == "$(rp c 251).png" ]] || return 1

  [[ "$(sanear_nuevo "$(rp ñ 130).jpg")" == "$(rp ñ 125).jpg" ]] || return 1
  if [[ ñ == [[:alnum:]] ]]; then
    [[ "$(sanear_nuevo "$(rp a 250).ñññññ")" == "$(rp a 244).ñññññ" ]] || return 1
  fi

  for largo_ext in .mp3 .7z .txt~ .a_b .c-d; do
    [[ "$(sanear_nuevo "$(rp z 300)$largo_ext")" == "$(rp z $((255 - ${#largo_ext})))$largo_ext" ]] || return 1
  done

  largo_ext="short.$(rp d 300)"
  [[ "$(sanear_nuevo "$largo_ext")" == "${largo_ext:0:255}" ]] || return 1
  [[ "$(sanear_nuevo "$(rp f 300).$(rp g 16)")" == "$(rp f 238).$(rp g 16)" ]] || return 1
  [[ "$(sanear_nuevo "$(rp e 300).$(rp x 17)")" == "$(rp e 255)" ]] || return 1
  [[ "$(sanear_nuevo "$(rp $'\xff' 300).jpg")" == sin_nombre_*.jpg ]] || return 1

  # The cut must not leave a space/tab at the end of the base, and the result must never be empty, "." or "..".
  [[ "$(sanear_nuevo "$(rp a 254) $(rp b 10)")" == "$(rp a 254)" ]] || return 1
  [[ "$(sanear_nuevo "$(rp a 254)"$'\t'"$(rp b 10)")" == "$(rp a 254)" ]] || return 1
  [[ "$(sanear_nuevo "$(rp a 250) $(rp b 10).jpg")" == "$(rp a 250).jpg" ]] || return 1
  [[ "$(sanear_nuevo ".$(rp ' ' 300)x")" == sin_nombre_* ]] || return 1
  [[ "$(sanear_nuevo "..$(rp ' ' 300)x")" == sin_nombre_* ]] || return 1
  [[ "$(sanear_nuevo '')" == sin_nombre_* && "$(sanear_nuevo '..')" == sin_nombre_* && "$(sanear_nuevo $' \t ')" == sin_nombre_* ]] || return 1
  [[ "$(sanear_nuevo $'\xff'"$(rp ' ' 300)x.jpg")" == sin_nombre_*.jpg ]] || return 1

  printf x > "$CASE_DIR/$largo.jpg"
  capture_cli en --archivo "$CASE_DIR/$largo.jpg" --metodo prefijo --prefijo "$pref" --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_absent "$CASE_DIR/$largo.jpg" || return 1
  assert_content "$CASE_DIR/$pref$(rp b 220).jpg" x || return 1
}

# The "(n)" suffix of a collision must not push a 255-byte name over the limit
# (the mv would fail with ENAMETOOLONG), nor split a UTF-8 character.
nombre_alternativo_limite_255_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  local largo alt i f total=0
  rp() { local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; }

  largo="$CASE_DIR/$(rp a 251).jpg"
  printf x > "$largo"
  nombre_alternativo "$largo" alt
  [[ "${alt##*/}" == "$(rp a 248)(1).jpg" ]] || return 1
  for i in 1 2 3 4 5 6 7 8 9; do printf x > "$CASE_DIR/$(rp a 248)($i).jpg"; done
  nombre_alternativo "$largo" alt
  [[ "${alt##*/}" == "$(rp a 247)(10).jpg" ]] || return 1

  largo="$CASE_DIR/a$(rp ñ 124).txt"
  printf x > "$largo"
  nombre_alternativo "$largo" alt
  [[ "${alt##*/}" == "a$(rp ñ 123)(1).txt" ]] || return 1
  printf '%s' "${alt##*/}" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || return 1

  rm -f -- "$CASE_DIR"/*
  printf 1 > "$CASE_DIR/one.jpg"; printf 2 > "$CASE_DIR/two.jpg"; printf 3 > "$CASE_DIR/three.jpg"
  capture_cli en --carpeta "$CASE_DIR" --metodo patron --patron "$(rp p 260){name}" --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  for f in "$CASE_DIR"/*; do
    [[ "$(printf '%s' "${f##*/}" | wc -c)" == 255 && "$f" == *.jpg ]] || return 1
    total=$((total + $(<"$f")))
  done
  (( total == 6 )) && [[ "$(find "$CASE_DIR" -type f | wc -l)" == 3 ]]
}

# The same file named twice ("a.txt", "./a.txt", an absolute path) is one item.
origenes_duplicados_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  local bin out
  mkdir "$CASE_DIR/sub"
  ln -s sub "$CASE_DIR/alias"
  printf a > "$CASE_DIR/a.txt"; printf b > "$CASE_DIR/b.txt"; printf c > "$CASE_DIR/sub/c.txt"; printf s > "$CASE_DIR/sub/a.txt"
  ln -s a.txt "$CASE_DIR/enlace.txt"

  fijar_origenes_unicos "$CASE_DIR/a.txt" "$CASE_DIR/./a.txt" "$CASE_DIR/sub/../a.txt" "$CASE_DIR/b.txt" "$CASE_DIR/a.txt"
  [[ "${#FILES[@]}" == 2 && "${FILES[0]}" == "$CASE_DIR/a.txt" && "${FILES[1]}" == "$CASE_DIR/b.txt" ]] || return 1
  fijar_origenes_unicos "$CASE_DIR/alias/c.txt" "$CASE_DIR/sub/c.txt"
  [[ "${#FILES[@]}" == 1 && "${FILES[0]}" == "$CASE_DIR/alias/c.txt" ]] || return 1
  # Same name in another directory, and a symlink next to its target, are different items.
  fijar_origenes_unicos "$CASE_DIR/a.txt" "$CASE_DIR/sub/a.txt" "$CASE_DIR/enlace.txt"
  (( ${#FILES[@]} == 3 )) || return 1
  fijar_origenes_unicos
  (( ${#FILES[@]} == 0 )) || return 1
  # Entries directly under "/" (empty directory part) work without errors.
  out=$(fijar_origenes_unicos /tmp //tmp 2>&1) || return 1
  [[ -z "$out" ]] || return 1
  fijar_origenes_unicos /tmp //tmp
  (( ${#FILES[@]} == 1 )) || return 1

  # One realpath call per directory, not per file.
  bin=$(mktemp -d "$TMP/bin.XXXXXX")
  printf '#!/usr/bin/env bash\necho x >> "%s/calls"\nexec %s "$@"\n' "$bin" "$(command -v realpath)" > "$bin/realpath"
  chmod +x "$bin/realpath"
  PATH="$bin:$PATH" fijar_origenes_unicos "$CASE_DIR/a.txt" "$CASE_DIR/b.txt" "$CASE_DIR/enlace.txt"
  [[ "$(wc -l < "$bin/calls")" == 1 ]] || return 1

  capture_cli en --archivo "$CASE_DIR/a.txt" --archivo "$CASE_DIR/./a.txt" --metodo prefijo --prefijo X_ --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_contains "$CLI_OUTPUT" '1 item(s) found' || return 1
  [[ "$CLI_OUTPUT" != *collision* && "$CLI_OUTPUT" != *'Could not prepare'* ]] || return 1
  assert_content "$CASE_DIR/X_a.txt" a || return 1
  assert_absent "$CASE_DIR/a.txt" || return 1

  # Relative and absolute spellings of the same file.
  (cd "$CASE_DIR" && run_cli en --archivo b.txt --archivo "$CASE_DIR/b.txt" --archivo ./b.txt --metodo prefijo --prefijo Y_ --sin-confirmar) > /dev/null 2>&1 || return 1
  assert_content "$CASE_DIR/Y_b.txt" b || return 1
  [[ "$(find "$CASE_DIR" -maxdepth 1 -name '*b.txt' | wc -l)" == 1 ]] || return 1

  # Positional arguments (Nemo) go through the same filter.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/zenity"
  chmod +x "$bin/zenity"
  printf 1 > "$CASE_DIR/one.txt"; printf 2 > "$CASE_DIR/two.txt"
  out=$(cd "$CASE_DIR" && PATH="$bin:$PATH" HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en \
    timeout 5 bash "$SCRIPT" one.txt "$CASE_DIR/one.txt" ./one.txt < /dev/null 2>&1)
  assert_contains "$out" '1 item(s) received from Nemo' || return 1
  out=$(cd "$CASE_DIR" && PATH="$bin:$PATH" HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en \
    timeout 5 bash "$SCRIPT" one.txt "$CASE_DIR/two.txt" ./one.txt < /dev/null 2>&1)
  assert_contains "$out" '2 item(s) received from Nemo' || return 1
}

# --lang es|en carries a description and stays out of the usage synopsis (both languages).
cli_help_lang_described_test() {
  new_case
  local lang
  for lang in es en; do
    capture_cli "$lang" --help
    (( CLI_RC == 0 )) || return 1
    grep -Eq '^  --lang es\|en  +[^ ]' <<< "$CLI_OUTPUT" || return 1
    ! grep -Eq '^  --lang es\|en *$' <<< "$CLI_OUTPUT" || return 1
    [[ "${CLI_OUTPUT%%$'\n\n'*}" != *--lang* ]] || return 1
  done
}

# A dangling symlink is an item like any other (the link itself is renamed or copied) in a
# folder, with --archivo and from Nemo; a link that resolves to "/" stays refused.
cli_dangling_symlink_test() {
  new_case
  local bin out
  mkdir "$CASE_DIR/src"
  printf a > "$CASE_DIR/src/a.txt"
  ln -s no_existe "$CASE_DIR/src/roto.lnk"

  capture_cli en --carpeta "$CASE_DIR/src" --metodo prefijo --prefijo X_ --dry-run --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_contains "$CLI_OUTPUT" '2 item(s) found' || return 1
  assert_contains "$CLI_OUTPUT" 'X_roto.lnk' || return 1

  bin=$(mktemp -d "$TMP/bin.XXXXXX")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/zenity"
  chmod +x "$bin/zenity"
  out=$(cd "$CASE_DIR/src" && PATH="$bin:$PATH" HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en \
    timeout 5 bash "$SCRIPT" roto.lnk < /dev/null 2>&1)
  assert_contains "$out" '1 item(s) received from Nemo' || return 1
  out=$(cd "$CASE_DIR/src" && PATH="$bin:$PATH" HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en \
    timeout 5 bash "$SCRIPT" roto.lnk a.txt < /dev/null 2>&1)
  assert_contains "$out" '2 item(s) received from Nemo' || return 1

  (export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en; source "$SCRIPT"
   autenticar_origen_ruta "$CASE_DIR/src/roto.lnk" && ! autenticar_origen_ruta "$CASE_DIR/src/falta") || return 1
  ln -s / "$CASE_DIR/src/rootlink"
  capture_cli en --archivo "$CASE_DIR/src/rootlink" --metodo prefijo --prefijo Z_ --dry-run --sin-confirmar
  (( CLI_RC == 1 )) || return 1
  assert_contains "$CLI_OUTPUT" 'cannot be processed safely' || return 1
  rm -f -- "$CASE_DIR/src/rootlink"

  capture_cli en --archivo "$CASE_DIR/src/a.txt" --archivo "$CASE_DIR/src/roto.lnk" --archivo "$CASE_DIR/src/falta" \
    --metodo prefijo --prefijo C_ --modo copiar --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  assert_contains "$CLI_OUTPUT" '2 item(s) found' || return 1
  assert_contains "$CLI_OUTPUT" 'Item does not exist' || return 1
  [[ -L "$CASE_DIR/src/roto.lnk" && "$(readlink "$CASE_DIR/src/C_roto.lnk")" == no_existe ]] || return 1

  capture_cli en --archivo "$CASE_DIR/src/roto.lnk" --metodo prefijo --prefijo X_ --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  [[ "$(readlink "$CASE_DIR/src/X_roto.lnk")" == no_existe ]] || return 1
  assert_absent "$CASE_DIR/src/roto.lnk" || return 1
  printf '1\n\n' | (
    export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
    source "$SCRIPT"
    deshacer_ultimo
  ) >/dev/null 2>&1 || return 1
  [[ "$(readlink "$CASE_DIR/src/roto.lnk")" == no_existe ]] || return 1
  assert_absent "$CASE_DIR/src/X_roto.lnk" || return 1
}

# BASH_VERSINFO is read-only: the real script runs with its name swapped for
# FAKE_BV, a fake array injected through BASH_ENV (executed and sourced).
bash_version_guard_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  local copy="$CASE_DIR/guard.sh" ver spec v ok out err rc
  ver=$(sed -n 's/^VERSION="\([0-9][0-9.]*\)"$/\1/p' "$SCRIPT" | head -n1)
  [[ "$(grep -m1 -vE '^[[:space:]]*(#|$)' "$SCRIPT")" == *BASH_VERSINFO* ]] || return 1
  sed 's/BASH_VERSINFO/FAKE_BV/g' "$SCRIPT" > "$copy"
  ! cmp -s "$SCRIPT" "$copy" || return 1
  for spec in 3.2:no 3.9:no 4.0:no 4.1:ok 4.4:ok 5.2:ok 10.0:ok; do
    v=${spec%:*} ok=${spec#*:}
    printf 'FAKE_BV=(%s %s 0 1 release x)\n' "${v%.*}" "${v#*.}" > "$CASE_DIR/env.sh"
    out=$(BASH_ENV="$CASE_DIR/env.sh" bash "$copy" --version 2> "$CASE_DIR/err"); rc=$?
    err=$(< "$CASE_DIR/err")
    if [[ $ok == ok ]]; then
      (( rc == 0 )) && [[ "$out" == "Renombrador $ver" && -z "$err" ]] || return 1
    else
      (( rc == 1 )) && [[ -z "$out" ]] || return 1
      assert_contains "$err" "requiere Bash 4.1 o superior (versión detectada: $v)." || return 1
      assert_contains "$err" "requires Bash 4.1 or newer (detected version: $v)." || return 1
    fi
    out=$(BASH_ENV="$CASE_DIR/env.sh" bash -c 'source "$1"; printf "%s %s" "$?" "${VERSION-unset}"' _ "$copy" 2> "$CASE_DIR/err")
    err=$(< "$CASE_DIR/err")
    if [[ $ok == ok ]]; then
      [[ "$out" == "0 $ver" && -z "$err" ]] || return 1
    else
      [[ "$out" == "1 unset" && "$err" == *"detectada: $v)."* && "$err" == *"detected version: $v)."* ]] || return 1
    fi
  done
}

importar_plantillas_almacen_ausente_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  template_flow_setup
  export PICK="$CASE_DIR/import.txt"
  printf 'Pre|PRE_{name}.{ext}\n' > "$PICK"
  rm -f "$TEMPLATES_FILE"
  run_fed '' importar_plantillas_desde_archivo
  (( RC == 0 )) || return 1
  assert_contains "$OUT" '1 template(s) imported' || return 1
  [[ "$OUT" != *'No such file'* && "$OUT" != *'storage'* ]] || return 1
  assert_content "$TEMPLATES_FILE" $'Pre|PRE_{name}.{ext}\n' || return 1
  rm -f "$TEMPLATES_FILE"
  run_fed $'s\n1' usar_plantilla_guardada
  [[ "$LEFT" == SENTINEL ]] || return 1
  assert_contains "$OUT" 'Applying «Pre»' || return 1
  [[ "${NOMBRES_COLA[*]}" == 'PRE_a.txt PRE_b.txt' ]] || return 1
}

deshacer_ultimo_eof_test() {
  new_case
  export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en
  source "$SCRIPT"
  local out
  printf x > "$CASE_DIR/a.txt"
  capture_cli en --archivo "$CASE_DIR/a.txt" --metodo prefijo --prefijo X_ --sin-confirmar
  (( CLI_RC == 0 )) && assert_file "$CASE_DIR/X_a.txt" || return 1
  # EOF (Ctrl-D) and "0" cancel; only a plain Enter means "most recent".
  out=$(deshacer_ultimo < /dev/null 2>&1)
  [[ "$out" != *Reverted* && "$out" != *'Invalid option'* ]] && assert_file "$CASE_DIR/X_a.txt" && assert_absent "$CASE_DIR/a.txt" || return 1
  out=$(printf '0\n' | deshacer_ultimo 2>&1)
  [[ "$out" != *Reverted* && "$out" != *'Invalid option'* ]] && assert_file "$CASE_DIR/X_a.txt" && assert_absent "$CASE_DIR/a.txt" || return 1
  (( $(nombres_lotes | wc -l) == 1 )) || return 1
  out=$(printf '\n\n' | deshacer_ultimo 2>&1)
  assert_contains "$out" 'Reverted: 1' || return 1
  assert_file "$CASE_DIR/a.txt" && assert_absent "$CASE_DIR/X_a.txt" || return 1
  (( $(nombres_lotes | wc -l) == 0 )) || return 1
}

cli_tilde_literal_test() {
  new_case
  local tl='~'
  mkdir -p "$CASE_HOME/docs" "$CASE_DIR/cwd/~dir"
  printf a > "$CASE_HOME/h.txt"
  printf b > "$CASE_DIR/cwd/"'~$doc.docx'
  printf c > "$CASE_DIR/cwd/~bob"
  printf d > "$CASE_DIR/cwd/~dir/in.txt"
  cd "$CASE_DIR/cwd" || return 1
  # Only "~" and "~/..." mean $HOME; any other leading "~" is a literal name.
  capture_cli en --archivo '~$doc.docx' --archivo '~bob' --metodo prefijo --prefijo X_ --dry-run
  (( CLI_RC == 0 )) && assert_contains "$CLI_OUTPUT" '2 item(s) found' && assert_contains "$CLI_OUTPUT" 'X_~$doc.docx' \
    && assert_contains "$CLI_OUTPUT" 'X_~bob' || return 1
  capture_cli en --carpeta '~dir' --metodo prefijo --prefijo X_ --dry-run
  (( CLI_RC == 0 )) && assert_contains "$CLI_OUTPUT" 'X_in.txt' || return 1
  capture_cli en --archivo "$tl/h.txt" --metodo prefijo --prefijo X_ --dry-run
  (( CLI_RC == 0 )) && assert_contains "$CLI_OUTPUT" 'X_h.txt' || return 1
  capture_cli en --carpeta "$tl" --metodo prefijo --prefijo X_ --dry-run
  (( CLI_RC == 0 )) && assert_contains "$CLI_OUTPUT" 'X_h.txt' || return 1
  capture_cli en --carpeta "$tl/docs" --metodo prefijo --prefijo X_ --dry-run
  (( CLI_RC == 1 )) && assert_contains "$CLI_OUTPUT" 'No items were found' || return 1
}

deshacer_copias_senal_en_omitidas_test() {
  new_case
  local f out rc log mode
  for f in a b c; do printf '%s' "$f" > "$CASE_DIR/$f.txt"; done
  capture_cli en --archivo "$CASE_DIR/a.txt" --archivo "$CASE_DIR/b.txt" --archivo "$CASE_DIR/c.txt" --metodo prefijo --prefijo C_ --modo copiar --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  mkdir -p "$CASE_DIR/bin"
  # Fake base64: its first encoding call (a pending line being written) signals the shell running the undo.
  cat > "$CASE_DIR/bin/base64" <<EOF
#!/usr/bin/env bash
marker="$CASE_DIR/.signaled"
if [[ "\${1:-}" != -d && ! -e "\$marker" ]]; then : > "\$marker"; kill -TERM "\$MAIN_PID"; sleep 0.2; fi
exec /usr/bin/base64 "\$@"
EOF
  chmod +x "$CASE_DIR/bin/base64"
  # The first copy is skipped (changed, then missing); the signal must still stop the loop before the next deletion.
  for mode in changed missing; do
    rm -f "$CASE_DIR/.signaled"
    if [[ "$mode" == changed ]]; then printf zz >> "$CASE_DIR/C_a.txt"; else rm -f "$CASE_DIR/C_a.txt"; fi
    out=$(printf '1\n\n' | (export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en PATH="$CASE_DIR/bin:$PATH" MAIN_PID=$BASHPID
                            source "$SCRIPT"; deshacer_ultimo) 2>&1)
    rc=$?
    (( rc == 143 )) && assert_contains "$out" 'Interrupted.' || return 1
    assert_file "$CASE_DIR/C_b.txt" && assert_file "$CASE_DIR/C_c.txt" || return 1
    log=$(find "$CASE_HOME/.config/renombrador/historial" -maxdepth 1 -name '*.log' -print -quit)
    [[ -n "$log" ]] && (( $(grep -vc '^#' "$log") == 3 )) || return 1
  done
}

deshacer_copias_fallo_de_rm_test() {
  new_case
  local out log
  printf a > "$CASE_DIR/a.txt"; printf b > "$CASE_DIR/b.txt"
  capture_cli en --archivo "$CASE_DIR/a.txt" --archivo "$CASE_DIR/b.txt" --metodo prefijo --prefijo C_ --modo copiar --sin-confirmar
  (( CLI_RC == 0 )) || return 1
  mkdir -p "$CASE_DIR/bin"
  printf '#!/usr/bin/env bash\n[[ "${1:-}" == -rf ]] && exit 1\nexec /usr/bin/rm "$@"\n' > "$CASE_DIR/bin/rm"
  chmod +x "$CASE_DIR/bin/rm"
  out=$(printf '1\n\n' | (export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en PATH="$CASE_DIR/bin:$PATH"; source "$SCRIPT"; deshacer_ultimo) 2>&1)
  assert_contains "$out" 'Copies deleted: 0' && assert_contains "$out" 'Failures: 2' || return 1
  assert_file "$CASE_DIR/C_a.txt" && assert_file "$CASE_DIR/C_b.txt" || return 1
  log=$(find "$CASE_HOME/.config/renombrador/historial" -maxdepth 1 -name '*.log' -print -quit)
  [[ -n "$log" ]] && (( $(grep -vc '^#' "$log") == 2 )) || return 1
  # The failed deletions stayed in the batch: a later undo with a working rm finishes them.
  out=$(printf '1\n\n' | (export HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en; source "$SCRIPT"; deshacer_ultimo) 2>&1)
  assert_contains "$out" 'Copies deleted: 2' || return 1
  assert_absent "$CASE_DIR/C_a.txt" && assert_absent "$CASE_DIR/C_b.txt" || return 1
  [[ -z "$(find "$CASE_HOME/.config/renombrador/historial" -maxdepth 1 -name '*.log' -print -quit)" ]] || return 1
}

menu_metodos_cancelar_conserva_cola_test() {
  new_case
  local out
  printf a > "$CASE_DIR/a.txt"; printf b > "$CASE_DIR/b.txt"
  # "Apply all" cancelled, then refused (unwritable folder, stubbed once): the queue is kept both times and
  # the real apply starts it over, even for a second batch.
  out=$(printf '2\nX_\na\n1\nn\n\na\n1\ny\n\na\n1\ny\n\n2\nY_\na\n1\nn\n\na\n1\ny\n\n0\n' \
    | HOME="$CASE_HOME" LC_ALL=C.UTF-8 RENOMBRADOR_LANG=en timeout 10 bash -c 'source "$1"
      FILES=("$2/a.txt" "$2/b.txt"); ro=1; directorio_solo_lectura() { (( ro )) || return 1; ro=0; }
      menu_metodos' _ "$SCRIPT" "$CASE_DIR" 2>&1)
  assert_contains "$out" 'Cancelled.' && assert_contains "$out" 'No changes were applied.' || return 1
  assert_file "$CASE_DIR/Y_X_a.txt" && assert_file "$CASE_DIR/Y_X_b.txt" || return 1
  assert_absent "$CASE_DIR/a.txt" && assert_absent "$CASE_DIR/X_a.txt" && assert_absent "$CASE_DIR/X_b.txt" || return 1
  # Piped input hides prompts, so "queue reset" is read off the last menu screen (no pending-steps subtitle).
  [[ "$out" != *'no steps'* && "${out##*Renamed: 2}" != *'queued but not applied'* ]] || return 1
}

TESTS=(
  project_integrity_test
  readme_integrity_test
  translation_contract_test
  pure_helpers_test
  pure_text_transformations_test
  pure_numbering_and_pattern_test
  patron_una_pasada_test
  atomic_file_write_test
  atomic_write_long_name_test
  atomic_persistence_test
  atomic_copy_persistence_test
  atomic_copy_subdir_fsync_test
  exportar_plantillas_modo_test
  copy_symlink_test
  icon_installation_test
  icon_standalone_test
  icon_reinstall_repairs_test
  icon_symlink_safety_test
  nemo_toggle_lifecycle_test
  nemo_manage_menu_test
  nemo_uninstall_failure_test
  history_fingerprint_failure_test
  history_fingerprint_stability_test
  config_symlink_safety_test
  config_dir_permissions_test
  config_dir_permissions_upgrade_test
  template_import_atomicity_test
  template_read_failure_test
  usar_plantilla_importar_aplicar_test
  usar_plantilla_respuesta_n_test
  usar_plantilla_cancelar_dialogo_test
  importar_plantillas_rechaza_binario_test
  importar_plantillas_limpia_crlf_bom_test
  importar_plantillas_directorio_inicial_test
  usar_plantilla_con_almacen_sin_pregunta_test
  importar_plantillas_sin_validas_test
  importar_plantillas_archivo_ilegible_test
  flock_plantillas_concurrency_test
  history_write_atomicity_test
  history_copy_write_atomicity_test
  signal_apply_move_deferred_test
  signal_apply_copy_partial_test
  barrer_huerfanos_sweep_test
  numero_en_rango_test
  eliminar_plantilla_race_test
  devolver_visible_apply_test
  devolver_visible_undo_test
  signal_undo_move_deferred_test
  signal_undo_copy_partial_test
  history_overwrite_rollback_test
  history_fingerprint_apply_failure_test
  adversarial_filenames_test
  translation_surface_test
  terminal_rendering_test
  locale_precedence_test
  saved_language_test
  nemo_action_language_test
  regex_injection_test
  risky_history_copy_undo_test
  risky_history_move_undo_test
  history_legacy_refusal_test
  history_malformed_test
  history_nested_undo_test
  history_nested_copy_undo_test
  cli_edge_cases_test
  symlink_boundary_test
  history_symlink_filter_test
  history_trailing_newline_path_test
  regex_newline_name_test
  terminal_user_data_safety_test
  terminal_escape_sanitization_test
  atomic_type_safety_test
  date_transformation_test
  cli_help_version_test
  cli_help_no_storage_test
  cli_help_nemo_flags_test
  cli_exit_code_partial_failure_test
  cli_validation_test
  cli_folder_selection_test
  interactive_yes_alias_test
  interactive_pattern_start_decimal_test
  menu_metodos_eof_test
  gestionar_plantillas_eof_test
  main_menu_eof_test
  cli_method_dispatch_smoke_test
  cli_move_copy_dryrun_test
  cli_conflict_policies_test
  cli_collision_test
  cli_numbering_order_test
  cli_template_test
  example_templates_test
  example_timestamp_templates_test
  exif_batch_cache_test
  cli_nested_directory_test
  history_undo_test
  sustituir_caracteres_incompatibles_test
  directorio_solo_lectura_test
  mover_item_incompatible_chars_test
  copia_item_atomica_incompatible_chars_test
  cli_incompatible_chars_retry_test
  cli_readonly_target_preflight_test
  sanear_nuevo_largo_conserva_extension_test
  importar_plantillas_recorta_espacios_test
  nombre_alternativo_limite_255_test
  icon_theme_refresh_test
  origenes_duplicados_test
  cli_help_lang_described_test
  cli_dangling_symlink_test
  bash_version_guard_test
  importar_plantillas_almacen_ausente_test
  deshacer_ultimo_eof_test
  cli_tilde_literal_test
  deshacer_copias_senal_en_omitidas_test
  deshacer_copias_fallo_de_rm_test
  menu_metodos_cancelar_conserva_cola_test
)

if (( $# > 0 )); then
  TESTS=("$@")
fi

for test_name in "${TESTS[@]}"; do
  run_test "$test_name" "$test_name"
done

printf '\nSummary: %d total, %d passed, %d failed, %d skipped\n' "$TOTAL" "$PASS" "$FAILS" "$SKIPS"
(( FAILS == 0 ))
