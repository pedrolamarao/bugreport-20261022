/**
 * Minimal reproducer, no dependencies.
 *
 *   java --enable-preview -Xbatch -XX:CompileCommand=dontinline,MinimalRepro::make MinimalRepro.java
 *
 * Expected: prints PASS. Observed with C2 (also with -XX:-TieredCompilation):
 *   FAIL at <i>: field = V[o=null]
 * Prints PASS with -Xint, with -XX:TieredStopAtLevel=1 (C1 only), with `record` instead of
 * `value record`, and with `if (isEmpty(r)) field = null; else field = r;` instead of the `?:`.
 *
 * `test` must store null when `isEmpty(r)` is true; C2 stores a non-null V(null) instead.
 * What is needed for the failure:
 *  - `r` comes from a call that is not inlined and whose declared return type is not V
 *    (with `static V make(...)` it passes);
 *  - `isEmpty` is inlined into `test` but has no branch profile of its own: `test` returns early
 *    in most calls, so `isEmpty` runs too rarely to be profiled before `test` is compiled
 *    (calling `test(true, ...)` every time makes it pass).
 * -Xbatch only makes the compile timing deterministic.
 */
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
