#!/usr/bin/env bash
#
# Runs Repro.java under several JIT configurations and summarises the outcome.
#
#   ./run.sh                    sync, default JIT, C1 only, no speculation    (~1 min)
#   ./run.sh --all              the above plus C2 only and -Xint              (~8 min, -Xint is slow)
#   ./run.sh c2 xint            only the named modes
#   ./run.sh -n 3 default c1    repeat every mode 3 times
#
# Modes:
#   sync      -XX:-BackgroundCompilation                              (default JIT, compiles synchronously;
#                                                                      the most reliable way to see the bug)
#   default   no extra JVM options (tiered compilation)               (timing-sensitive: a slow or loaded
#                                                                      machine can make a run PASS)
#   c2        -XX:-TieredCompilation                                  (C2 only)
#   c1        -XX:TieredStopAtLevel=1                                 (C1 only)
#   notraps   -XX:PerMethodTrapLimit=0 -XX:PerBytecodeTrapLimit=0     (no speculation)
#   xint      -Xint                                                   (interpreter only)
#
# Environment:
#   JAVA             path to the java launcher (default: $JAVA_HOME/bin/java, then `java` on PATH)
#   HEGEL_LIB_DIR    directory holding hegel-0.10.2.jar and hegel-lowlevel-0.10.2.jar
#                    (default: ./lib, downloaded from Maven Central when missing)
#   RUN_TIMEOUT      seconds allowed for each run (default 900)
#
# Exit status: 0 when the bug reproduced as expected (some C2 mode FAILs and no control mode does),
#              1 when it did not (nothing failed, or a control mode failed), 2 on a setup error.

set -u

HEGEL_VERSION=0.10.2
MAVEN=https://repo1.maven.org/maven2/dev/hegel

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
lib=${HEGEL_LIB_DIR:-$here/lib}
timeout_s=${RUN_TIMEOUT:-900}

die() { echo "run.sh: $*" >&2; exit 2; }

declare -A options=(
    [sync]="-XX:-BackgroundCompilation"
    [default]=""
    [c2]="-XX:-TieredCompilation"
    [c1]="-XX:TieredStopAtLevel=1"
    [notraps]="-XX:PerMethodTrapLimit=0 -XX:PerBytecodeTrapLimit=0"
    [xint]="-Xint"
)
bug_modes="sync default c2"     # modes in which the bug is expected
control_modes="c1 notraps xint" # modes in which it is not

repeat=1
modes=()
while [ $# -gt 0 ]; do
    case $1 in
        --all) modes=(sync default c2 c1 notraps xint) ;;
        -n)    shift; repeat=${1:?-n needs a number} ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)     [ -n "${options[$1]+x}" ] || die "unknown mode '$1' (known: ${!options[*]})"
               modes+=("$1") ;;
    esac
    shift
done
[ ${#modes[@]} -gt 0 ] || modes=(sync default c1 notraps)

# ---- java ------------------------------------------------------------------------------------

if [ -n "${JAVA:-}" ]; then java=$JAVA
elif [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then java=$JAVA_HOME/bin/java
else java=$(command -v java) || die "no java found: set JAVA or JAVA_HOME"
fi
version_line=$("$java" -version 2>&1 | head -n 3 | tr '\n' ' ')
major=$("$java" -version 2>&1 | sed -n '1s/.*version "\([0-9]*\).*/\1/p')
[ -n "$major" ] || die "cannot parse the java version from: $version_line"

# ---- Hegel jars ------------------------------------------------------------------------------

jars=()
for artifact in hegel hegel-lowlevel; do
    jar=$lib/$artifact-$HEGEL_VERSION.jar
    if [ ! -f "$jar" ]; then
        mkdir -p "$lib" || die "cannot create $lib"
        url=$MAVEN/$artifact/$HEGEL_VERSION/$artifact-$HEGEL_VERSION.jar
        echo "downloading $url"
        if command -v curl >/dev/null; then curl -fsSL -o "$jar.part" "$url"
        elif command -v wget >/dev/null; then wget -q -O "$jar.part" "$url"
        else die "need curl or wget to download $url (or put the jars in $lib)"
        fi || { rm -f "$jar.part"; die "download failed: $url"; }
        mv "$jar.part" "$jar"
    fi
    jars+=("$jar")
done
classpath=$(IFS=:; echo "${jars[*]}")

# ---- run -------------------------------------------------------------------------------------

echo "java:  $version_line"
echo "mode:  --enable-preview --source $major (Repro.java), Hegel $HEGEL_VERSION, timeout ${timeout_s}s per run"
echo

declare -A pass=() fail=()
cd "$here" || die "cannot cd to $here"

for mode in "${modes[@]}"; do
    for i in $(seq "$repeat"); do
        printf '%-8s run %d/%d  %-60s ' "$mode" "$i" "$repeat" "${options[$mode]:-(no extra options)}"
        start=$SECONDS
        # shellcheck disable=SC2086  # the option strings are meant to be split
        out=$(timeout "$timeout_s" "$java" ${options[$mode]} --enable-preview \
                --enable-native-access=ALL-UNNAMED -cp "$classpath" --source "$major" Repro.java 2>/dev/null)
        status=$?
        result=$(printf '%s\n' "$out" | grep -E '^(PASS|FAIL)' | tail -n 1)
        elapsed=$((SECONDS - start))
        case $result in
            PASS*) pass[$mode]=$(( ${pass[$mode]:-0} + 1 )) ;;
            FAIL*) fail[$mode]=$(( ${fail[$mode]:-0} + 1 )) ;;
            *)     result="ERROR (exit status $status; no PASS/FAIL line)" ;;
        esac
        printf '%s  [%ds]\n' "${result:0:90}" "$elapsed"
    done
done

# ---- summary ---------------------------------------------------------------------------------

echo
printf '%-8s %5s %5s\n' mode pass fail
for mode in "${modes[@]}"; do
    printf '%-8s %5d %5d\n' "$mode" "${pass[$mode]:-0}" "${fail[$mode]:-0}"
done
echo

bug_seen=0; control_failed=0
for mode in "${modes[@]}"; do
    case " $bug_modes "     in *" $mode "*) [ "${fail[$mode]:-0}" -gt 0 ] && bug_seen=1 ;; esac
    case " $control_modes " in *" $mode "*) [ "${fail[$mode]:-0}" -gt 0 ] && control_failed=1 ;; esac
done

if [ $bug_seen = 1 ] && [ $control_failed = 0 ]; then
    echo "REPRODUCED: a C2 mode fails and the control modes pass."
    exit 0
elif [ $control_failed = 1 ]; then
    echo "UNEXPECTED: a control mode (c1, notraps or xint) failed."
    exit 1
else
    echo "NOT REPRODUCED: no run failed (JIT timing matters: try './run.sh -n 3 sync c1')."
    exit 1
fi
