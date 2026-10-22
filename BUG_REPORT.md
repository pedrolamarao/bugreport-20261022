# C2 stores a non-null void value object for `cond ? null : valueObject` (Valhalla EA build)

## Summary

In a Valhalla early-access build, C2-compiled code for the pattern

```java
position = line.isVoid(result) ? null : result;   // `position` is a field of interface type; `result` is a value record
```

stores a **non-null** value object (`new PositionImpl(null)`) where the source says it must store
`null`. The wrong value is observed later, when `position != null` is true although it must be false,
and the void position reaches code that dereferences its single field (`NullPointerException`).

The program is correct in the interpreter and under C1; it only fails once C2 has compiled the
methods containing the pattern. A plain (identity) `record` instead of `value record` does not fail.

I could reduce the failure to one source file, but it needs a property-testing library (Hegel) to
drive the code. I did not manage to remove it (see "What I could not do").

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
- Classes compiled and run with `--enable-preview` (`value record` is used).
- Only dependency: Hegel 0.10.2 (`dev.hegel:hegel:0.10.2` and `dev.hegel:hegel-lowlevel:0.10.2`, from Maven Central).

## How to reproduce

`Repro.java` (attached, single file, ~210 lines). With `HCP` set to the two Hegel jars:

```
HCP=hegel-0.10.2.jar:hegel-lowlevel-0.10.2.jar

java --enable-preview --enable-native-access=ALL-UNNAMED -cp $HCP --source 28 Repro.java
```

Expected: `PASS`.
Actual (default JIT):

```
FAIL: NullPointerException: Cannot read field "link" because "<local3>" is null
```

The Hegel seed is fixed in the file, so the generated test cases are the same on every run.
`./run.sh` (attached) downloads the two jars from Maven Central, runs the modes listed below and
prints a summary. Hegel's jar bundles its native engine (`libhegel.so` for linux-amd64, extracted to
`~/.cache/hegel-java`), so nothing else is needed.

The failure depends on JIT timing: background compilation means that the profile seen by C2
depends on how far the test has run when the compile starts. One run on a busy machine (with other
JVMs running) passed, and 1 of 6 runs passed with 12 CPU-bound processes running at the same time. With
`-XX:-BackgroundCompilation` (compile synchronously) it failed 6 of 6 on an idle machine and 6 of 6
under that load, so use that option (`./run.sh sync`) if the default configuration does not fail
for you.

### Results (this machine, fixed seed; 3 runs per row unless noted)

| JVM options                                                    | Result              |
|----------------------------------------------------------------|---------------------|
| `-XX:-BackgroundCompilation` (default JIT, synchronous)        | FAIL, 6 of 6 idle, 6 of 6 under CPU load |
| *(default, tiered)*                                            | FAIL, 3 of 3 (also 10 of 10 across two seeds; 8 of 8 via `run.sh`); timing-sensitive, see above |
| `-XX:-TieredCompilation` (C2 only)                             | FAIL, 3 of 3        |
| `-XX:TieredStopAtLevel=1` (C1 only)                            | PASS, 3 of 3        |
| `-Xint`                                                        | PASS, 1 of 1 (takes ~6 min for 5000 cases) |
| `-XX:PerMethodTrapLimit=0 -XX:PerBytecodeTrapLimit=0`          | PASS, 3 of 3        |

### Further results with `Repro.java`

All with `-XX:-BackgroundCompilation` unless noted; `M` is `Repro$StructureMachine`.

| Change                                                                 | Result              |
|------------------------------------------------------------------------|---------------------|
| `record` instead of `value record` (sync, and once with default JIT)    | PASS, 4 of 4        |
| `-XX:CompileCommand=dontinline,Repro$SparseCircle::isVoid`             | PASS, 2 of 2        |
| `-XX:CompileCommand=exclude,M::insertAfter`                            | **FAIL**, 2 of 2    |
| exclude `M::insertAfter` and `M::removeBase`                           | **FAIL**, 2 of 2    |
| exclude `M::insertAfter` and `M::removeAfter`                          | PASS, 2 of 2        |
| exclude `M::removeBase` and `M::removeAfter` (with or without `M::insertAfter`) | PASS, 4 of 4 |
| exclude `M::removeAfter` only (default JIT)                            | PASS, 1 of 1        |
| `-XX:-TieredCompilation`, exclude `M::insertAfter` and `M::removeAfter` | **FAIL**, 1 of 1 (shrinks to the `removeBase` sequence) |
| `-XX:-TieredCompilation`, exclude `M::insertAfter` and `M::removeBase`  | PASS, 1 of 1        |
| `-XX:-UseTypeProfile` (default JIT)                                    | FAIL, 4 of 4        |
| any one of `-XX:-DoEscapeAnalysis`, `-XX:-EliminateAllocations`, `-XX:+UnlockDiagnosticVMOptions -XX:-ReduceAllocationMerges`, `-XX:-OptimizePtrCompare`, `-XX:-SplitIfBlocks`, `-XX:+UnlockDiagnosticVMOptions -XX:-UseFieldFlattening` | FAIL, 2 of 2 each |

What this shows:

- **The wrong value is in the field, not in the null check that reads it.** With
  `StructureMachine::insertAfter` excluded from compilation, the `position != null` check runs in the
  interpreter and still lets the void position through. So the compiled rule that writes `position`
  stored a non-null `PositionImpl(null)`.
- **Either rule that contains the pattern is enough, and which one depends on the mode:** with tiered
  compilation (default or `-XX:-BackgroundCompilation`) the compiled `removeAfter` causes the failure;
  with `-XX:-TieredCompilation` the compiled `removeBase` causes it.
- Escape analysis, allocation elimination and field flattening are not needed for the failure.
- Adding any check to the start of `StructureMachine.insertAfter` (e.g. throwing if `position` is void)
  makes the failure disappear; I read this only as more timing/profile sensitivity.

The same code, as a Gradle/JUnit test in a larger project, showed the same split (interpreter and
C1 pass; C2 fails in every run I made, more than 15 in total; `-Xint` passed 3 of 3 with 2000 test cases). In that larger project
`record` instead of `value record` and `dontinline` of `isVoid` also made it pass, and no other
`dontinline` I tried did. `-XX:-UseTypeProfile` made it pass in the larger project but **not** in
`Repro.java`, so I do not consider it informative.

## What the program does

`Repro.java` is a stateful model-based test of a circular singly linked list. Positions are
`value record PositionImpl<U>(Node<U> node)`; the *void* position is `PositionImpl(null)` and must
never be stored as "no position". The test keeps `Position position` (nullable, interface type) and
the rules are:

```java
void removeBase(TestCase t) {
    t.assume(count != 0);
    var result = line.removeBase();                  // returns PositionImpl(null) when the circle becomes empty
    ...
    if (line.notVoid(result)) assertDistanceEquals(result.next(), result::equals, count - 2);
    count -= 1;
    position = line.isVoid(result) ? null : result;  // <- stores a non-null PositionImpl(null) under C2
}

void removeAfter(TestCase t) {
    t.assume(position != null);
    ...
    var result = line.removeAfter(reference);        // returns PositionImpl(null) when the circle becomes empty
    ...
    count -= 1;
    position = line.isVoid(result) ? null : result;  // <- same pattern, same wrong value under C2
}

void insertAfter(TestCase t) {
    t.assume(position != null);                      // <- passes although position must be null
    var reference = position;
    ...
    line.insertAfter(reference, value);              // NPE: ((PositionImpl) reference).node is null
}
```

The failing sequence depends on the JIT mode:

- With `-XX:-TieredCompilation`, Hegel shrinks the failure to `insertBase(1); removeBase(); insertAfter(2)`.
- With the default JIT and with `-XX:-BackgroundCompilation`, the final case is not shrunk: it has 36
  steps (most of them rejected by `assume`) and ends in `...; insertBase(9); removeAfter(); insertAfter(10)`,
  starting from an empty circle. Hegel prints `note: unconfirmed failure: failed 0 of 48 replays after
  the observed failure`: the same case passes when replayed right after the failure (presumably because
  the compiled code has been deoptimized or recompiled by then), so Hegel cannot shrink it.

In both cases the second-to-last rule empties the circle, so `position` must be `null` and the last
rule must be rejected by `assume`.

One inference that may help (for the `removeBase` case, `-XX:-TieredCompilation`): with the circle
empty, `count` is 1 when `removeBase` reaches the guard
`if (line.notVoid(result)) assertDistanceEquals(..., count - 2)`. If `notVoid(result)` had evaluated to
true, that call would have thrown `AssertionError("distance not zero")`. It did not. So the guard is
evaluated correctly inside the same compiled method, and only the value produced by the conditional
expression (`isVoid(result) ? null : result`) is wrong.

## Observations from `-XX:+PrintCompilation` (larger project, C2 only)

- The two affected rules are compiled by C2 shortly before the failure; `PositionImpl::next` and other
  rules are made not entrant by "uncommon trap" events in the same period, i.e. the failing code is
  running with profile-based speculation.
- Disabling speculation (`PerMethodTrapLimit=0 PerBytecodeTrapLimit=0`) makes the failure disappear.

I did not collect a C2 IR / `-XX:+PrintInlining` dump for the failing compile: with
`PrintInlining` enabled the run I tried passed (the run is timing-sensitive).

## What I could not do

- **A reproducer without Hegel.** I tried about ten hand-written drivers (random rule sequences, the
  exact rule bodies, a warm-up phase in which `removeBase` never empties the circle, reflective
  dispatch, a `TestCase`-like object that throws on `assume`, even the real test machine and the real
  Hegel `TestCase` with my own random driver). All of them pass with C2 for the same code. Hegel's
  `Stateful.run` produces some call/profile history that I could not reproduce by hand.
- I did not look at the generated code, so I cannot say which C2 phase is responsible (only that
  escape analysis and allocation elimination are not required, see above). The behaviour
  looks like a nullable value object whose only field is `null` being confused with, or merged as, a
  non-null value at the `?:` merge, but that is a guess.

## Workarounds

- Run with `-XX:TieredStopAtLevel=1`, or with `-XX:PerMethodTrapLimit=0 -XX:PerBytecodeTrapLimit=0`.
- Avoid the pattern (e.g. use an explicit `if`/`else`) — untested.

## Attachments

- `Repro.java`: single-file reproducer (needs the two Hegel jars on the class path).
- `run.sh`: downloads the jars and runs `Repro.java` in each mode (`sync`, `default`, `c2`, `c1`, `notraps`, `xint`).
