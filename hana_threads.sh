#!/bin/bash
## Builds the thread_count version of the thread-samples script.
## The SQL heredoc (read -r -d '' SQL_TEMPLATE_CONTENT ... SQL_EOF) is copied
## byte-for-byte from the original; only the code before and after it changes.
##
## Usage: ./apply_thread_count.sh <original_script.sh> <new_script.sh>
set -euo pipefail
src="${1:?usage: $0 original.sh new.sh}"
dst="${2:?usage: $0 original.sh new.sh}"
[[ -r "${src}" ]] || { echo "cannot read ${src}" >&2; exit 1; }
[[ "$(readlink -f "${src}")" != "$(readlink -f "${dst}" 2>/dev/null || echo x)" ]] || { echo "output must differ from input" >&2; exit 1; }

start=$(grep -n "^read -r -d '' SQL_TEMPLATE_CONTENT <<'SQL_EOF'" "${src}" | head -1 | cut -d: -f1)
end=$(grep -n '^SQL_EOF$' "${src}" | head -1 | cut -d: -f1)
[[ -n "${start}" && -n "${end}" && "${end}" -gt "${start}" ]] || { echo "SQL heredoc not found in ${src}" >&2; exit 1; }
grep -q 'HANA_Threads_ThreadSamples_FilterAndAggregation' "${src}" || echo "WARNING: ${src} does not look like the thread-samples script" >&2

{
cat <<'HEAD_EOF'
#!/bin/bash
trap "exit 1" TERM
export TOP_PID=$$

die() {
  echo "ERROR: $*" >&2
  kill -s TERM "${TOP_PID}"
}

if [ "$#" -eq 8 ] || [ "$#" -eq 9 ]; then
        db_sid=${1}          ## HANA installation SID (used for the hdbsql binary path)
        db_inst_no=${2}      ## HANA instance number
        db_tenant=${3}       ## tenant database name for hdbsql -d (e.g. SEC on an S08
                             ## installation). Pass 'same' when the tenant name matches
                             ## the installation SID; SYSTEMDB queries the system database.
        schemaName=${4}      ## schema / connect user name
        db_password=${5}     ## DB password, or 'none' to use hdbuserstore key <schemaName>
        begin_time=${6}      ## BEGIN_TIME for the thread sample window
        end_time=${7}        ## END_TIME for the thread sample window
        script_dir=${8}/hana_dbop_comparison
        thread_count=${9:-3} ## OPTIONAL: number of top STATEMENT_HASH values to extract and
                             ## publish (1-10). 3 -> thread1..thread3, 5 -> thread1..thread5.
                             ## Default 3 keeps existing 8-parameter jobs unchanged.

        ## Convenience: an empty value or the literal 'same'/'none' means the tenant
        ## name equals the installation SID, which keeps single-tenant systems simple.
        if [[ -z "${db_tenant}" || "${db_tenant}" == "same" || "${db_tenant}" == "SAME" \
              || "${db_tenant}" == "none" || "${db_tenant}" == "NONE" ]]; then
                db_tenant="${db_sid}"
        fi
else
        echo "Parameter missing"
        echo "Usage: $0 db_sid db_inst_no tenant_db_sid schemaName db_password begin_time end_time script_dir [thread_count]"
        echo "       tenant_db_sid is the database passed to hdbsql -d (e.g. SEC for installation S08)"
        echo "       use 'same' (or the SID itself) when the tenant name equals the installation SID"
        echo "       use SYSTEMDB to query the system database instead of a tenant"
        echo "       thread_count (optional, 1-10, default 3) = how many top statement hashes to publish"
        exit 1
fi

## Validate thread_count early so a typo fails before the (long) SQL runs.
MAX_THREADS=10
[[ -z "${thread_count}" ]] && thread_count=3
if ! [[ "${thread_count}" =~ ^[0-9]+$ ]] || (( 10#${thread_count} < 1 || 10#${thread_count} > MAX_THREADS )); then
        echo "ERROR: thread_count must be a number between 1 and ${MAX_THREADS}, got '${thread_count}'" >&2
        exit 1
fi
thread_count=$(( 10#${thread_count} ))

## The orchestrating platform passes timestamps as a single whitespace-free
## token (e.g. 2026/08/19_00:26:20) so the value survives unquoted expansion on
## the command line. Turn the separator back into a space before it reaches the
## SQL. Shortcut forms (C, C-H2, E-S900, MIN, MAX, ...) contain no underscore and
## are passed through untouched.
normalize_time() {
  if [[ "${1}" =~ ^([0-9]{4}/[0-9]{2}/[0-9]{2})_([0-9]{2}:[0-9]{2}:[0-9]{2})$ ]]; then
    printf '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf '%s' "${1}"
  fi
}
begin_time="$(normalize_time "${begin_time}")"
end_time="$(normalize_time "${end_time}")"

## Validate the tenant name so a bad value fails here instead of producing a
## confusing hdbsql connection error later on.
if [[ -z "${db_tenant}" ]] || ! [[ "${db_tenant}" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]; then
        die "tenant_db_sid must be a valid database name, got '${db_tenant}'"
fi

HDBSQL_BIN="/usr/sap/${db_sid}/HDB${db_inst_no}/exe/hdbsql"
db_name="${db_tenant}"    ## tenant / system database name passed to hdbsql -d

if [[ ! -x "${HDBSQL_BIN}" ]]; then
  die "hdbsql binary not found or not executable at ${HDBSQL_BIN}"
fi

mkdir -p "${script_dir}" || die "Could not create working directory ${script_dir}"

HEAD_EOF

sed -n "${start},${end}p" "${src}"

cat <<'TAIL_EOF'

ts="$(date +%Y%m%d_%H%M%S)"
TMP_SQL="${script_dir}/hana_thread_samples_${db_tenant}_${ts}.sql"
OUTPUT_FILE="${script_dir}/hana_thread_samples_${db_tenant}_${ts}.out"

esc_begin="$(printf '%s' "${begin_time}" | sed -e 's/[&/\]/\\&/g')"
esc_end="$(printf '%s' "${end_time}" | sed -e 's/[&/\]/\\&/g')"

printf '%s\n' "${SQL_TEMPLATE_CONTENT}" | sed \
  -e "s/__BEGIN_TIME__/${esc_begin}/" \
  -e "s/__END_TIME__/${esc_end}/" \
  > "${TMP_SQL}" || die "Failed to generate SQL at ${TMP_SQL}"

echo "sid=${db_sid} inst=${db_inst_no} tenant=${db_name} thread_count=${thread_count}" >&2
echo "Generated SQL with BEGIN_TIME='${begin_time}' END_TIME='${end_time}' -> ${TMP_SQL}" >&2

HDBSQL_ARGS=(-i "${db_inst_no}" -d "${db_name}")

if [[ "${db_password}" == "none" || "${db_password}" == "NONE" ]]; then
  # By default the hdbuserstore key is assumed to be named after the schema /
  # connect user. On systems with several tenants the key is usually per tenant,
  # so it can be overridden by exporting HDBUSERSTORE_KEY before calling this
  # script (e.g. HDBUSERSTORE_KEY=SYMSEC).
  HDBUSERSTORE_KEY="${HDBUSERSTORE_KEY:-${schemaName}}"
  HDBSQL_ARGS+=(-U "${HDBUSERSTORE_KEY}")
else
  HDBSQL_ARGS+=(-u "${schemaName}" -p "${db_password}")
fi

HDBSQL_ARGS+=(-I "${TMP_SQL}" -o "${OUTPUT_FILE}")

"${HDBSQL_BIN}" "${HDBSQL_ARGS[@]}" || die "hdbsql execution failed"

echo "Output written to ${OUTPUT_FILE}"

# --- Extract the top <thread_count> STATEMENT_HASH values (rows are already ORDER BY sample count DESC) ---
# hdbsql -o writes standard CSV: an unquoted header row, then quoted data rows, then a
# trailing "N rows selected (...)" footer. TABLE_NAMES can itself contain embedded commas
# (STRING_AGG(..., ', ')), so a naive comma-split would misalign every column after it -
# a real CSV parser is required. We use python's csv module and find STATEMENT_HASH
# dynamically from the header rather than hard-coding a column position.
PYEXE="$(command -v python3 || command -v python)"
if [[ -z "${PYEXE}" ]]; then
  die "Neither python3 nor python found on PATH; needed to parse CSV output for STATEMENT_HASH extraction"
fi

top_hashes="$("${PYEXE}" - "${OUTPUT_FILE}" "${thread_count}" <<'PYEOF'
import csv
import sys

path = sys.argv[1]
limit = int(sys.argv[2])
results = []
seen = set()

with open(path, newline='', encoding='utf-8', errors='replace') as f:
    reader = csv.reader(f)
    try:
        header = next(reader)
    except StopIteration:
        header = []
    header = [h.strip() for h in header]
    try:
        idx = header.index('STATEMENT_HASH')
    except ValueError:
        idx = -1

    if idx != -1:
        for row in reader:
            if idx >= len(row):
                continue
            val = row[idx].strip()
            if val in ('', '-- Others --', 'any'):
                continue
            if val.lower().startswith('no sql'):
                # e.g. 'no SQL (JobWorker)', 'no SQL (merging)', 'no SQL (GCJob)' -
                # background/non-SQL threads have no real statement hash, skip them
                continue
            if val not in seen:
                seen.add(val)
                results.append(val)
            if len(results) >= limit:
                break

for r in results:
    print(r)
PYEOF
)"

## Fixed slots thread1..thread10; only the first thread_count can be filled.
thread1="$(sed -n '1p'  <<< "${top_hashes}")"
thread2="$(sed -n '2p'  <<< "${top_hashes}")"
thread3="$(sed -n '3p'  <<< "${top_hashes}")"
thread4="$(sed -n '4p'  <<< "${top_hashes}")"
thread5="$(sed -n '5p'  <<< "${top_hashes}")"
thread6="$(sed -n '6p'  <<< "${top_hashes}")"
thread7="$(sed -n '7p'  <<< "${top_hashes}")"
thread8="$(sed -n '8p'  <<< "${top_hashes}")"
thread9="$(sed -n '9p'  <<< "${top_hashes}")"
thread10="$(sed -n '10p' <<< "${top_hashes}")"

found_count=$(grep -c . <<< "${top_hashes}" || true)
echo
echo "Top STATEMENT_HASH values (requested ${thread_count}, found ${found_count}):"
[[ -n "${top_hashes}" ]] && awk '{ printf "  thread%d=%s\n", NR, $0 }' <<< "${top_hashes}"
if (( found_count < thread_count )); then
  echo "NOTE: only ${found_count} real statement hash(es) in the sample window - fewer than thread_count=${thread_count}." >&2
fi

## One marker per line, each guarded so an absent hash is simply not published.
## Using if/fi rather than "[[ ... ]] && echo" also keeps the exit status at 0
## when a hash is missing - a bare && on the final line would leave the script
## exiting 1 and the calling step would read that as a failure.
if [[ -n "${thread1}" ]]; then
  echo "##gbStart##thread1##splitKeyValue##${thread1}##splitKeyValue##string##gbEnd##"
fi

if [[ -n "${thread2}" ]]; then
  echo "##gbStart##thread2##splitKeyValue##${thread2}##splitKeyValue##string##gbEnd##"
fi

if [[ -n "${thread3}" ]]; then
  echo "##gbStart##thread3##splitKeyValue##${thread3}##splitKeyValue##string##gbEnd##"
fi

if [[ -n "${thread4}" ]]; then
  echo "##gbStart##thread4##splitKeyValue##${thread4}##splitKeyValue##string##gbEnd##"
fi

if [[ -n "${thread5}" ]]; then
  echo "##gbStart##thread5##splitKeyValue##${thread5}##splitKeyValue##string##gbEnd##"
fi

if [[ -n "${thread6}" ]]; then
  echo "##gbStart##thread6##splitKeyValue##${thread6}##splitKeyValue##string##gbEnd##"
fi

if [[ -n "${thread7}" ]]; then
  echo "##gbStart##thread7##splitKeyValue##${thread7}##splitKeyValue##string##gbEnd##"
fi

if [[ -n "${thread8}" ]]; then
  echo "##gbStart##thread8##splitKeyValue##${thread8}##splitKeyValue##string##gbEnd##"
fi

if [[ -n "${thread9}" ]]; then
  echo "##gbStart##thread9##splitKeyValue##${thread9}##splitKeyValue##string##gbEnd##"
fi

if [[ -n "${thread10}" ]]; then
  echo "##gbStart##thread10##splitKeyValue##${thread10}##splitKeyValue##string##gbEnd##"
fi

exit 0
TAIL_EOF
} > "${dst}"

chmod +x "${dst}"
bash -n "${dst}" || { echo "syntax check FAILED for ${dst}" >&2; exit 1; }

## Prove the SQL block is identical to the original
if diff <(sed -n "${start},${end}p" "${src}") \
        <(sed -n "/^read -r -d '' SQL_TEMPLATE_CONTENT <<'SQL_EOF'/,/^SQL_EOF\$/p" "${dst}") >/dev/null; then
  echo "OK: ${dst} created, SQL block identical to ${src} (lines ${start}-${end}), bash -n passed"
else
  echo "ERROR: SQL block differs - do not use ${dst}" >&2; exit 1
fi
