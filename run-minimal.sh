#!/usr/bin/env bash
#
# Runs MinimalRepro.java under several JIT configurations and summarises the outcome.
#
#   ./run-minimal.sh            all modes, once each (a few seconds)
#   ./run-minimal.sh -n 3       repeat every mode 3 times
#
# Every mode except xint and nodontinline also passes -XX:CompileCommand=dontinline,MinimalRepro::make.
#
# Environment:
#   JAVA    path to the java launcher (default: $JAVA_HOME/bin/java, then `java` on PATH)
#
# Exit status: 0 when the bug reproduced as expected (every C2 mode FAILs and every control mode
#              PASSes), 1 otherwise, 2 on a setup error.

set -u

die() { echo "run-minimal.sh: $*" >&2; exit 2; }

repeat=1
while [ $# -gt 0 ]; do
    case $1 in
        -n) shift; repeat=${1:?-n needs a number} ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)  die "unknown argument '$1'" ;;
    esac
    shift
done

if [ -n "${JAVA:-}" ]; then java=$JAVA
elif [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then java=$JAVA_HOME/bin/java
else java=$(command -v java) || die "no java found: set JAVA or JAVA_HOME"
fi

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$here" || die "cannot cd to $here"

dontinline=-XX:CompileCommand=dontinline,MinimalRepro::make
modes=(batch batch-c2 default c2 notraps c1 xint nodontinline)
declare -A options=(
    [batch]="-Xbatch $dontinline"
    [batch-c2]="-Xbatch -XX:-TieredCompilation $dontinline"
    [default]="$dontinline"
    [c2]="-XX:-TieredCompilation $dontinline"
    [notraps]="-Xbatch -XX:PerMethodTrapLimit=0 -XX:PerBytecodeTrapLimit=0 $dontinline"
    [c1]="-Xbatch -XX:TieredStopAtLevel=1 $dontinline"
    [xint]="-Xint"
    [nodontinline]="-Xbatch"
)
bug_modes="batch batch-c2 default c2 notraps"
control_modes="c1 xint nodontinline"

echo "java:  $("$java" -version 2>&1 | head -n 3 | tr '\n' ' ')"
echo

declare -A pass=() fail=()
for mode in "${modes[@]}"; do
    for i in $(seq "$repeat"); do
        printf '%-13s run %d/%d  %-100s ' "$mode" "$i" "$repeat" "${options[$mode]}"
        # shellcheck disable=SC2086  # the option strings are meant to be split
        result=$("$java" ${options[$mode]} -XX:CompileCommand=quiet --enable-preview MinimalRepro.java 2>&1 \
                 | grep -E '^(PASS|FAIL)' | tail -n 1)
        case $result in
            PASS*) pass[$mode]=$(( ${pass[$mode]:-0} + 1 )) ;;
            FAIL*) fail[$mode]=$(( ${fail[$mode]:-0} + 1 )) ;;
            *)     result="ERROR (no PASS/FAIL line)" ;;
        esac
        echo "$result"
    done
done

echo
ok=1
for mode in $bug_modes;     do [ "${pass[$mode]:-0}" -eq 0 ] && [ "${fail[$mode]:-0}" -gt 0 ] || ok=0; done
for mode in $control_modes; do [ "${fail[$mode]:-0}" -eq 0 ] && [ "${pass[$mode]:-0}" -gt 0 ] || ok=0; done
if [ $ok = 1 ]; then
    echo "REPRODUCED: every C2 mode fails and every control mode passes."
    exit 0
else
    echo "NOT AS EXPECTED: see the table above (C2 modes: $bug_modes; controls: $control_modes)."
    exit 1
fi
