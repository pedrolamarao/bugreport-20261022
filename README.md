# C2 stores a non-null value object for `isEmpty(v) ? null : v` (Valhalla EA build)

## Summary

In a Valhalla early-access build, C2-compiled code for

```java
field = isEmpty(r) ? null : r;   // r: a value object typed as Object; isEmpty(r) is `((V) r).o == null`
```

stores a **non-null** value object `V(null)` in `field` when `isEmpty(r)` is true, where the source
says it must store `null`.

The failure needs three things:

- `r` comes from a call that is not inlined and whose declared return type is not the value class;
- `isEmpty` is inlined but has no branch profile of its own (it ran too rarely to be profiled);
- the `?:`, since the same code written as `if`/`else` passes.

The program is correct in the interpreter and under C1. A plain (identity) `record` instead of
`value record` does not fail.

## Environment

```
$ java -version
openjdk version "28-ea" 2027-03-23
OpenJDK Runtime Environment (build 28-ea+20-1588)
OpenJDK 64-Bit Server VM (build 28-ea+20-1588, mixed mode, sharing)

$ grep SOURCE $JAVA_HOME/release
SOURCE=".:git:84054dbf1760"
```

- Linux x86_64, CentOS Stream 10, kernel 6.12.0, 8 CPUs, G1 (default), no extra JVM flags other than those listed.
- Run with `--enable-preview` (`value record` is used).

## How to reproduce

`MinimalRepro.java` (attached, no dependencies):

```java
public class MinimalRepro {
    value record V(Object o) {}

    static Object field;

    static Object make(boolean empty) { return new V(empty ? null : new Object()); }

    static boolean isEmpty(Object p) { return ((V) p).o == null; }

    static void test(boolean go, boolean empty) {
        if (!go) return;
        Object r = make(empty);
        field = isEmpty(r) ? null : r;
    }

    public static void main(String[] args) {
        for (int i = 0; i < 100_000; i++) {
            test(i % 8 == 0, i % 16 == 0);
            if (field != null && ((V) field).o == null) {
                System.out.println("FAIL at " + i + ": field = " + field);
                return;
            }
        }
        System.out.println("PASS");
    }
}
```

```
java --enable-preview -Xbatch -XX:CompileCommand=dontinline,MinimalRepro::make MinimalRepro.java
```

Expected: `PASS`. Actual:

```
FAIL at 5376: field = V[o=null]
```

`./run-minimal.sh` (attached) runs it in the modes below. `-Xbatch` only makes the result
deterministic (the failure always happens at the same iteration); without it the failure also showed up in
every run I made, at a later iteration.

### Results (`MinimalRepro.java`)

All with `-XX:CompileCommand=dontinline,MinimalRepro::make` unless noted.

| JVM options / change                                               | Result               |
|--------------------------------------------------------------------|----------------------|
| `-Xbatch` (tiered)                                                 | FAIL, 3 of 3 (always at 5376) |
| `-Xbatch -XX:-TieredCompilation`                                   | FAIL, 3 of 3 (always at 6784) |
| *(no extra options, tiered)*                                       | FAIL, 6 of 6         |
| `-XX:-TieredCompilation`                                           | FAIL, 6 of 6         |
| `-Xbatch -XX:PerMethodTrapLimit=0 -XX:PerBytecodeTrapLimit=0`      | **FAIL**, 3 of 3     |
| `-Xbatch -XX:TieredStopAtLevel=1` (C1 only)                        | PASS, 3 of 3         |
| `-Xint`                                                            | PASS, 2 of 2         |
| `-Xbatch`, without the `dontinline` (so `make` is inlined)         | PASS, 3 of 3         |
| `-Xbatch -XX:CompileCommand=exclude,MinimalRepro::test`            | PASS                 |
| `-Xbatch -XX:CompileCommand=exclude,MinimalRepro::main`            | FAIL                 |

Changes to the source, each tried with `-Xbatch` both tiered and with `-XX:-TieredCompilation`:

| Change                                                              | Result |
|---------------------------------------------------------------------|--------|
| `record` instead of `value record`                                  | PASS (tiered) |
| `static V make(...)` instead of `static Object make(...)`           | PASS   |
| `if (isEmpty(r)) field = null; else field = r;` instead of the `?:` | PASS   |
| `test(true, i % 2 == 0)`, i.e. `isEmpty` runs on every call of `test` | PASS (tiered) |
| `((V) r).o == null ? null : r` written inline instead of calling `isEmpty` | PASS (tiered) |
| `Object x = isEmpty(r) ? null : r; field = x;`                       | FAIL   |
| `static V field` (and `V r = (V) make(empty)`)                      | FAIL   |
| `V`, `make`, `field` and `isEmpty` all typed with `V`               | PASS   |

## Analysis

- **`test` is the miscompiled method, and the value really is in the field.** Excluding `test` from
  compilation makes it pass. Excluding `main` still fails, so the check that sees `V[o=null]` runs in
  the interpreter.
- **`isEmpty` has no branch profile in the failing compile.** With `-XX:+LogCompilation` (both tiered and
  `-XX:-TieredCompilation`), the compile of `test` inlines `isEmpty`, logging the `checkcast` at bci 1 with
  `null_check` and `class_check` traps. But there is no `<branch>` entry for its `ifnonnull` at bci 7:
  `test` returns early in 7 of 8 calls, so `isEmpty` has run only a few hundred times when `test` is
  compiled (672 tiered, 848 C2 only). When `isEmpty` runs on every call of `test`, it gets profiled and the failure goes away;
  `-XX:CompileCommand=dontinline` of `isEmpty` also made the original program (below) pass.
- **Speculation is not needed.** It still fails with `-XX:PerMethodTrapLimit=0 -XX:PerBytecodeTrapLimit=0`.
  (In the original program those flags made it pass, because there the cold `isVoid` came from a
  deoptimization and recompilation; see below.)
- Escape analysis, allocation elimination and field flattening are not needed. In the original program each
  of `-XX:-DoEscapeAnalysis`, `-XX:-EliminateAllocations`, `-XX:-ReduceAllocationMerges`,
  `-XX:-OptimizePtrCompare`, `-XX:-SplitIfBlocks`, `-XX:-UseFieldFlattening` still failed.

My guess is that C2 merges `null` and the value object `r` at the `?:` into a scalarized value with a
null marker, and the store into `field` re-allocates a `V` from its field values without honouring the null
marker. But I did not look at the IR (this is a product build, without `PrintIdeal`).

## Original reproducer

I first saw the bug in a stateful property-based test, using the Hegel 0.10.2 library, of a circular linked
list whose positions are `value record PositionImpl(Node node)`. `Repro.java` (attached, needs
`hegel-0.10.2.jar` and `hegel-lowlevel-0.10.2.jar` from Maven Central; `./run.sh` downloads them and
runs it in several modes) contains the same pattern:

```java
position = line.isVoid(result) ? null : result;   // result from the non-inlined line.removeBase()
```

The program fails under C2 in every configuration I tried: default, `-XX:-BackgroundCompilation`,
`-XX:-TieredCompilation`. It passes with `-Xint`, with C1 only, with `record` instead of `value record`,
with `dontinline` of `isVoid`, and with `-XX:PerMethodTrapLimit=0 -XX:PerBytecodeTrapLimit=0`.

Reducing it showed why a hand-written driver did not fail. Hegel calls each rule thousands of times,
and almost every call is rejected by `assume(...)` before reaching the rest of the rule. In the
`-XX:-TieredCompilation` compile log of a reduced version of `Repro.java`, `removeBase` had 6796 calls
before the first compile, all with
`count == 0`. So the first compile turned the rest of the method into an uncommon trap. After the trap,
it was recompiled with only 496 calls past the `assume`, and `isVoid` was again too cold to have a
profile. That is the same shape as `MinimalRepro.test`, and with traps disabled the first compile has
no such history.

## Workarounds

- Run with `-XX:TieredStopAtLevel=1`.
- Write the code as `if`/`else` instead of `?:` (tested on `MinimalRepro.java` only).

## Attachments

- `MinimalRepro.java`: minimal reproducer, no dependencies.
- `run-minimal.sh`: runs `MinimalRepro.java` in the modes listed above.
- `Repro.java`: original reproducer (needs Hegel 0.10.2).
- `run.sh`: downloads Hegel and runs `Repro.java` in each mode (`sync`, `default`, `c2`, `c1`, `notraps`, `xint`).
