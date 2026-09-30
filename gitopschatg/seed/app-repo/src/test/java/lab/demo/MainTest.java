package lab.demo;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

class MainTest {
    @Test
    void messageIsStable() {
        assertEquals("Hello from the GitOps demo app", Main.message());
    }
}
