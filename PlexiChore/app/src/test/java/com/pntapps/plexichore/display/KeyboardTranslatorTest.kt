package com.pntapps.plexichore.display

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyboardTranslatorTest {
    private val out = ArrayList<KeyOut>()
    private var resets = 0
    private val t = KeyboardTranslator { out.add(it) }.apply { onImeResetNeeded = { resets++ } }

    private fun text(s: String) = KeyOut.Text(s)
    private fun tap(code: Int) = listOf(KeyOut.Key(code, true), KeyOut.Key(code, false))
    private val del = tap(KeyCodes.DEL)

    /** Applies the KEY stream to a simulated host text field (backspace = one grapheme). */
    private fun hostText(events: List<KeyOut>): String {
        val g = ArrayList<String>()
        for (e in events) when (e) {
            is KeyOut.Text -> g.addAll(KeyboardTranslator.graphemes(e.text))
            is KeyOut.Key -> if (e.down && e.keyCode == KeyCodes.DEL && g.isNotEmpty()) g.removeAt(g.lastIndex)
                else if (e.down && e.keyCode == KeyCodes.ENTER) g.add("\n")
        }
        return g.joinToString("")
    }

    @Test fun plainTyping() {
        t.commitText("h"); t.commitText("i"); t.commitText(" ")
        assertEquals(listOf(text("h"), text("i"), text(" ")), out)
        assertEquals("", t.composing)
    }

    @Test fun composingIsMirroredAsDiffs() {
        t.setComposingText("h")
        t.setComposingText("he")
        t.setComposingText("hel")
        assertEquals(listOf(text("h"), text("e"), text("l")), out)
        t.commitText("hel ")
        assertEquals(text(" "), out.last())
        assertEquals("hel ", hostText(out))
    }

    @Test fun predictionReplacingAWord() {
        "teh".forEach { t.setComposingText(t.composing + it) }
        out.clear()
        t.commitText("the ") // autocorrect
        assertEquals(del + del + listOf(text("he ")), out)
    }

    @Test fun predictionPickedFromSuggestionStrip() {
        listOf("w", "wo", "wor").forEach { t.setComposingText(it) }
        t.commitText("world")
        t.commitText(" ")
        assertEquals("world ", hostText(out))
    }

    @Test fun backspaceWhileComposing() {
        listOf("c", "ca", "cat").forEach { t.setComposingText(it) }
        t.setComposingText("ca")
        assertEquals(del, out.takeLast(2))
        t.setComposingText("car")
        t.finishComposingText()
        assertEquals("car", hostText(out))
        assertEquals("", t.composing)
    }

    @Test fun backspaceOnEmptyBufferIsDel() {
        t.commitText("ab")
        t.imeKey(KeyCodes.DEL)
        t.deleteSurroundingText(1, 0)
        assertEquals("", hostText(out))
        assertEquals(text("ab"), out.first())
        assertEquals(del + del, out.drop(1))
    }

    @Test fun deleteSurroundingForward() {
        t.deleteSurroundingText(0, 2)
        assertEquals(tap(KeyCodes.FORWARD_DEL) + tap(KeyCodes.FORWARD_DEL), out)
    }

    @Test fun deleteSurroundingTrimsComposing() {
        t.setComposingText("abc")
        t.deleteSurroundingText(1, 0)
        assertEquals("ab", t.composing)
        t.commitText("ab ")
        assertEquals("ab ", hostText(out))
    }

    @Test fun emojiAndSurrogatePairs() {
        t.setComposingText("hi👍")
        t.setComposingText("hi")
        assertEquals(text("hi👍"), out[0])
        assertEquals(del, out.drop(1)) // one backspace removes the whole pair
        out.clear()
        t.setComposingText("hi👍🏽") // emoji + skin tone = one grapheme
        t.setComposingText("hi👍🏿")
        assertEquals(listOf(text("👍🏽")) + del + listOf(text("👍🏿")), out)
        t.commitText("hi👍🏿")
        assertEquals("hi👍🏿", hostText(listOf(text("hi")) + out))
    }

    @Test fun newline() {
        t.commitText("a\r\nb\rc\n")
        assertEquals(listOf(text("a\nb\nc\n")), out)
        out.clear()
        t.editorAction()
        assertEquals(tap(KeyCodes.ENTER), out)
        out.clear()
        t.imeKey(KeyCodes.ENTER)
        assertEquals(tap(KeyCodes.ENTER), out)
    }

    @Test fun oneShotModifierTurnsTextIntoKeyCodes() {
        val changes = ArrayList<Set<StickyModifier>>()
        t.onModifiersChanged = { armed, _ -> changes.add(armed) }
        t.toggleModifier(StickyModifier.META)
        t.commitText("c")
        assertEquals(
            listOf(
                KeyOut.Key(KeyCodes.META_LEFT, true),
                KeyOut.Key(KeyCodes.A + 2, true), KeyOut.Key(KeyCodes.A + 2, false),
                KeyOut.Key(KeyCodes.META_LEFT, false),
            ),
            out,
        )
        assertEquals(listOf(setOf(StickyModifier.META), emptySet<StickyModifier>()), changes)
        out.clear()
        t.commitText("v") // one-shot: no modifier any more
        assertEquals(listOf(text("v")), out)
    }

    @Test fun modifierWithUppercaseAndSymbolAddsShift() {
        t.toggleModifier(StickyModifier.CTRL)
        t.commitText("Z")
        assertEquals(
            listOf(
                KeyOut.Key(KeyCodes.SHIFT_LEFT, true), KeyOut.Key(KeyCodes.CTRL_LEFT, true),
                KeyOut.Key(KeyCodes.A + 25, true), KeyOut.Key(KeyCodes.A + 25, false),
                KeyOut.Key(KeyCodes.CTRL_LEFT, false), KeyOut.Key(KeyCodes.SHIFT_LEFT, false),
            ),
            out,
        )
        assertEquals(KeyCodes.forChar('?'), 76 to true)
        assertEquals(KeyCodes.forChar('1'), 8 to false)
    }

    @Test fun modifierChordWhileComposingResetsIme() {
        t.toggleModifier(StickyModifier.CTRL)
        t.setComposingText("a")
        assertEquals(1, resets)
        assertEquals("", t.composing)
        assertTrue(out.none { it is KeyOut.Text })
    }

    @Test fun lockedModifierStaysUntilTappedAgain() {
        t.toggleModifier(StickyModifier.ALT)
        t.toggleModifier(StickyModifier.ALT) // double tap = lock
        t.press(KeyCodes.DPAD_LEFT)
        t.press(KeyCodes.DPAD_RIGHT)
        assertEquals(2, out.count { it == KeyOut.Key(KeyCodes.ALT_LEFT, true) })
        assertEquals(setOf(StickyModifier.ALT), t.lockedModifiers)
        t.toggleModifier(StickyModifier.ALT)
        out.clear()
        t.press(KeyCodes.TAB)
        assertEquals(tap(KeyCodes.TAB), out)
    }

    @Test fun keyRepeatKeepsOneShotUntilRelease() {
        t.toggleModifier(StickyModifier.CTRL)
        repeat(3) { t.press(KeyCodes.DEL, consume = false) }
        t.consumeOneShot()
        assertEquals(3, out.count { it == KeyOut.Key(KeyCodes.CTRL_LEFT, true) })
        assertTrue(t.armedModifiers.isEmpty())
    }

    @Test fun resetClearsEverything() {
        t.toggleModifier(StickyModifier.CTRL)
        t.setComposingText("x")
        t.reset()
        assertEquals("", t.composing)
        assertTrue(t.armedModifiers.isEmpty() && t.lockedModifiers.isEmpty())
    }
}
