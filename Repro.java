import dev.hegel.Generator;
import dev.hegel.Generators;
import dev.hegel.Hegel;
import dev.hegel.Rule;
import dev.hegel.Settings;
import dev.hegel.Stateful;
import dev.hegel.TestCase;

import java.util.function.Predicate;

/**
 * Single-file reproducer (needs the Hegel property-testing library 0.10.2 on the class path).
 *
 *   java --enable-preview --enable-native-access=ALL-UNNAMED -cp hegel-0.10.2.jar:hegel-lowlevel-0.10.2.jar \
 *        --source 28 Repro.java
 *
 * Expected: prints PASS. Observed with C2 (default JIT, or -XX:-TieredCompilation): prints
 *   FAIL: NullPointerException ... in SparseCircle.insertAfter
 * Prints PASS with -Xint, with -XX:TieredStopAtLevel=1 (C1 only) and with
 *   -XX:PerMethodTrapLimit=0 -XX:PerBytecodeTrapLimit=0.
 *
 * The fixed Hegel seed makes the generated test cases deterministic; the JIT timing is still
 * not, but the failure showed up in every run with this seed.
 *
 * What the failing run does: a rule empties the circle, so it must store null in `position`
 * (position = line.isVoid(result) ? null : result). Compiled by C2 it stores a non-null void
 * position object instead, so the assume(position != null) of insertAfter() passes and the
 * void position (PositionImpl(null)) reaches insertAfter(). Which rule does it depends on the mode:
 *   -XX:-TieredCompilation: Hegel shrinks to insertBase(1); removeBase(); insertAfter(2);
 *   default and -XX:-BackgroundCompilation: the final case is not shrunk (36 steps) and ends in
 *     ...; insertBase(9); removeAfter(); insertAfter(10).
 */
public class Repro {

    // ---- circular singly linked list whose positions are value objects ------------------------

    static final class Node<T> {
        T content;
        Node<T> link;
        Node(T content, Node<T> link) { this.content = content; this.link = link; }
    }

    interface Position { Position next(); }

    interface Circle<T> {
        Position base();
        boolean isVoid(Position position);
        default boolean notVoid(Position position) { return !isVoid(position); }
        Position insertBase(T content);
        Position insertAfter(Position reference, T content);
        Position removeBase();
        Position removeAfter(Position reference);
    }

    static final class SparseCircle<T> implements Circle<T> {
        value record PositionImpl<U>(Node<U> node) implements Position {
            public Position next() {
                if (node == null) return new PositionImpl<>(null);
                return new PositionImpl<>(node.link);
            }
        }

        private Node<T> head, tail;

        public Position base() { return new PositionImpl<>(head); }

        public boolean isVoid(Position position) { return ((PositionImpl<T>) position).node == null; }

        public Position insertBase(T content) {
            if (head == null) {
                var inserted = new Node<>(content, null);
                inserted.link = inserted;
                head = inserted;
                tail = inserted;
                return new PositionImpl<>(inserted);
            }
            var inserted = new Node<>(content, head);
            tail.link = inserted;
            head = inserted;
            return new PositionImpl<>(inserted);
        }

        public Position insertAfter(Position position, T content) {
            var reference = ((PositionImpl<T>) position).node;
            var inserted = new Node<>(content, reference.link);   // NPE here: reference == null
            reference.link = inserted;
            if (reference == tail) tail = inserted;
            return new PositionImpl<>(inserted);
        }

        public Position removeBase() {
            if (head == tail) { head = null; tail = null; return base(); }
            tail.link = head.link;
            head = head.link;
            return base();
        }

        public Position removeAfter(Position position) {
            var reference = ((PositionImpl<T>) position).node;
            var target = reference.link;
            if (reference == target) { head = null; tail = null; return base(); }
            var next = target.link;
            reference.link = next;
            if (target == tail) tail = reference;
            if (target == head) head = next;
            return new PositionImpl<>(next);
        }
    }

    // ---- model-based test ---------------------------------------------------------------------

    static void assertDistanceEquals(Position start, Predicate<Position> finish, long distance) {
        var p = start;
        while (!finish.test(p) && distance != 0) { p = p.next(); distance -= 1; }
        if (!finish.test(p)) throw new AssertionError("position not finish");
        if (distance != 0) throw new AssertionError("distance not zero");
    }

    static int measure(Position start, Predicate<Position> finish, long limit) {
        int distance = 0;
        var p = start;
        while (!finish.test(p) && limit > 0) { p = p.next(); distance += 1; limit -= 1; }
        return distance;
    }

    static class StructureMachine {
        long count = 0;
        Circle<Integer> line;
        Position position = null;
        int unique = 0;

        StructureMachine(Circle<Integer> line) { this.line = line; }

        Generator<Integer> unique() { return Generators.just(++unique); }

        @Rule
        void insertBase(TestCase t) {
            var value = t.draw(unique(), "value");
            var result = line.insertBase(value);
            if (!result.equals(line.base())) throw new AssertionError("insertBase");
            assertDistanceEquals(result.next(), result::equals, count);
            count += 1;
            position = result;
        }

        @Rule
        void positionBase(TestCase t) {
            t.assume(count != 0);
            position = line.base();
        }

        @Rule
        void removeBase(TestCase t) {
            t.assume(count != 0);
            var result = line.removeBase();
            if (!result.equals(line.base())) throw new AssertionError("removeBase");
            if (line.notVoid(result)) assertDistanceEquals(result.next(), result::equals, count - 2);
            count -= 1;
            position = line.isVoid(result) ? null : result;   // C2 stores a non-null (void) position here (C2 only mode)
        }

        @Rule
        void insertAfter(TestCase t) {
            t.assume(position != null);
            var reference = position;
            var rank = measure(line.base(), reference::equals, count);
            var value = t.draw(unique(), "value");
            var result = line.insertAfter(reference, value);
            assertDistanceEquals(line.base(), result::equals, rank + 1);
            count += 1;
            position = result;
        }

        @Rule
        void positionAfter(TestCase t) {
            t.assume(position != null);
            position = position.next();
        }

        @Rule
        void removeAfter(TestCase t) {
            t.assume(position != null);
            var reference = position;
            var rank = measure(line.base(), reference::equals, count);
            var targetIsBase = reference.next().equals(line.base());
            var result = line.removeAfter(reference);
            if (targetIsBase) {
                if (!result.equals(line.base())) throw new AssertionError("removeAfter base");
            } else {
                assertDistanceEquals(line.base(), result::equals, (rank + 1) % (count - 1));
            }
            count -= 1;
            position = line.isVoid(result) ? null : result;   // ... and here (default tiered mode)
        }
    }

    public static void main(String[] args) {
        try {
            Hegel.test(t -> Stateful.run(new StructureMachine(new SparseCircle<>()), t),
                    new Settings().testCases(5000).seed(1));
            System.out.println("PASS");
        } catch (Throwable e) {
            Throwable c = e;
            while (c.getCause() != null && !(c instanceof NullPointerException)) c = c.getCause();
            System.out.println("FAIL: " + c.getClass().getSimpleName() + ": " + c.getMessage());
        }
    }
}
