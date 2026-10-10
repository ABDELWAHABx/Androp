package app.androp.android.presentation.ui.components

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MacKeyboardTest {
    @Test fun shiftedSymbolsUseTheirPhysicalKeyWithShift() {
        assertEquals(MacKeycodes.getKeyCode('1'), MacKeycodes.getKeyCode('!'))
        assertTrue(MacKeycodes.requiresShift('!'))
        assertTrue(MacKeycodes.requiresShift('?'))
        assertTrue(MacKeycodes.requiresShift('A'))
        assertFalse(MacKeycodes.requiresShift('1'))
        assertFalse(MacKeycodes.requiresShift('-'))
        assertFalse(MacKeycodes.requiresShift('a'))
    }
}
