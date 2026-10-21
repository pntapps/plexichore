package com.pntapps.plexichore.display

import java.text.BreakIterator

/** Sticky one-shot modifiers of the extra-keys row, with the Android key code sent for each. */
internal enum class StickyModifier(val keyCode: Int) {
    CTRL(KeyCodes.CTRL_LEFT),
    ALT(KeyCodes.ALT_LEFT),
    META(KeyCodes.META_LEFT),
}

/** One KEY message (PROTOCOL.md 0x05) to send to the host. */
internal sealed interface KeyOut {
    data class Key(val keyCode: Int, val down: Boolean) : KeyOut
    /** Typed as Unicode by the host ("\n" = Return). Sent as a single "down". */
    data class Text(val text: String) : KeyOut
}

/** Android `KeyEvent.KEYCODE_*` values used here (plain ints so this file stays JVM-testable). */
internal object KeyCodes {
    const val DPAD_UP = 19
    const val DPAD_DOWN = 20
    const val DPAD_LEFT = 21
    const val DPAD_RIGHT = 22
    const val A = 29
    const val ALT_LEFT = 57
    const val SHIFT_LEFT = 59
    const val TAB = 61
    const val SPACE = 62
    const val ENTER = 66
    const val DEL = 67
    const val ESCAPE = 111
    const val FORWARD_DEL = 112
    const val CTRL_LEFT = 113
    const val META_LEFT = 117
    const val MOVE_HOME = 122
    const val MOVE_END = 123

    private val plain = HashMap<Char, Int>().apply {
        for (i in 0 until 26) put('a' + i, A + i)
        for (i in 0 until 10) put('0' + i, 7 + i)
        put(' ', SPACE); put('\n', ENTER); put('\t', TAB)
        put(',', 55); put('.', 56); put('-', 69); put('=', 70); put('[', 71); put(']', 72)
        put('\\', 73); put(';', 74); put('\'', 75); put('/', 76); put('`', 68)
    }

    /** US-layout shifted symbols → their unshifted key. */
    private val shifted = mapOf(
        '!' to '1', '@' to '2', '#' to '3', '$' to '4', '%' to '5', '^' to '6', '&' to '7', '*' to '8',
        '(' to '9', ')' to '0', '_' to '-', '+' to '=', '{' to '[', '}' to ']', '|' to '\\', ':' to ';',
        '"' to '\'', '?' to '/', '~' to '`', '<' to ',', '>' to '.',
    )

    /** Key code (+ whether Shift is needed) for one character, or null when no US key types it. */
    fun forChar(c: Char): Pair<Int, Boolean>? {
        plain[c]?.let { return it to false }
        if (c in 'A'..'Z') return (A + (c - 'A')) to true
        shifted[c]?.let { base -> return plain.getValue(base) to true }
        return null
    }
}

/**
 * Turns what an IME does to our (invisible, empty) editor into KEY messages for the host. Pure logic,
 * main-thread only.
 *
 * The host's focused text field is the real editor: committed text is typed there right away. While
 * the IME composes (prediction / autocorrect, even with suggestions off some keyboards do), the
 * composing string is mirrored on the host as well, and every change is sent as a *diff*: backspaces
 * for the graphemes that changed, then the new tail — so "helo" → "hello " sends 1 × DEL + "lo ".
 *
 * Sticky modifiers (Ctrl / Alt / Meta from the extra-keys row) are applied to the next key: tap =
 * one-shot, second tap = locked until tapped again. A character typed while one is active is sent as
 * a key code (Ctrl+C, ⌘V…), because hosts apply modifiers to key codes, not to Unicode text.
 */
internal class KeyboardTranslator(private val emit: (KeyOut) -> Unit) {

    /** Composing text as currently mirrored on the host. */
    var composing: String = ""
        private set

    private val armed = LinkedHashSet<StickyModifier>()
    private val locked = LinkedHashSet<StickyModifier>()

    /** Called whenever the armed / locked modifier sets change. */
    var onModifiersChanged: ((armed: Set<StickyModifier>, locked: Set<StickyModifier>) -> Unit)? = null

    /**
     * Called when a modifier chord swallowed text the IME still believes is composing; the caller
     * should restart the IME input so both sides agree on an empty editor again.
     */
    var onImeResetNeeded: (() -> Unit)? = null

    val armedModifiers: Set<StickyModifier> get() = armed.toSet()
    val lockedModifiers: Set<StickyModifier> get() = locked.toSet()

    // ---- IME InputConnection -------------------------------------------------------------

    fun commitText(text: CharSequence) {
        replaceComposing(normalize(text))
        composing = ""
    }

    fun setComposingText(text: CharSequence) {
        val t = normalize(text)
        if (replaceComposing(t)) {
            composing = ""
            onImeResetNeeded?.invoke()
        } else composing = t
    }

    /** The composing text stays as typed on the host. */
    fun finishComposingText() {
        composing = ""
    }

    /** [before] backspaces and [after] forward deletes (graphemes ≈ what one host keypress removes). */
    fun deleteSurroundingText(before: Int, after: Int) {
        if (before <= 0 && after <= 0) return
        val mods = activeModifiers()
        repeat(before.coerceIn(0, MAX_DELETE)) { chord(KeyCodes.DEL, mods) }
        repeat(after.coerceIn(0, MAX_DELETE)) { chord(KeyCodes.FORWARD_DEL, mods) }
        if (before > 0 && composing.isNotEmpty()) {
            val g = graphemes(composing)
            composing = g.dropLast(minOf(before, g.size)).joinToString("")
        }
        consumeOneShot()
    }

    /**
     * A raw key event from the IME (Backspace on an empty buffer, Enter, arrows…), sent as one key
     * press with any armed modifiers. [shift] = the event had Shift held.
     */
    fun imeKey(keyCode: Int, shift: Boolean = false) {
        if (keyCode == KeyCodes.DEL && composing.isNotEmpty()) {
            composing = graphemes(composing).dropLast(1).joinToString("")
        } else composing = ""
        press(keyCode, extraShift = shift)
    }

    /** Editor action (the IME's Enter / Go / Done key). */
    fun editorAction() {
        composing = ""
        press(KeyCodes.ENTER)
    }

    // ---- Extra-keys row ------------------------------------------------------------------

    /**
     * One key press (down + up) with the active modifiers. With [consume] false the one-shot
     * modifiers stay armed (key repeat); call [consumeOneShot] when the key is released.
     */
    fun press(keyCode: Int, consume: Boolean = true, extraShift: Boolean = false) {
        val mods = activeModifiers()
        chord(keyCode, if (extraShift) mods + KeyCodes.SHIFT_LEFT else mods)
        if (consume) consumeOneShot()
    }

    /** Tap: off → armed (one-shot) → locked → off. */
    fun toggleModifier(m: StickyModifier) {
        when (m) {
            in locked -> { locked.remove(m); armed.remove(m) }
            in armed -> { armed.remove(m); locked.add(m) }
            else -> armed.add(m)
        }
        notifyModifiers()
    }

    fun consumeOneShot() {
        if (armed.isEmpty()) return
        armed.clear()
        notifyModifiers()
    }

    /** Session end / keyboard closed: forget composing text and all modifiers. */
    fun reset() {
        composing = ""
        if (armed.isEmpty() && locked.isEmpty()) return
        armed.clear()
        locked.clear()
        notifyModifiers()
    }

    // ---- Internals -----------------------------------------------------------------------

    /** Brings the host from [composing] to [target]. Returns true when a modifier chord consumed the text. */
    private fun replaceComposing(target: String): Boolean {
        val old = graphemes(composing)
        val new = graphemes(target)
        var p = 0
        while (p < old.size && p < new.size && old[p] == new[p]) p++
        repeat(old.size - p) { chord(KeyCodes.DEL, emptyList()) }
        if (p == new.size) return false
        val added = new.subList(p, new.size)
        val mods = activeModifiers()
        if (mods.isNotEmpty()) {
            val first = added[0]
            val mapped = if (first.length == 1) KeyCodes.forChar(first[0]) else null
            if (mapped != null) {
                chord(mapped.first, if (mapped.second) mods + KeyCodes.SHIFT_LEFT else mods)
                consumeOneShot()
                if (added.size > 1) emit(KeyOut.Text(added.subList(1, added.size).joinToString("")))
                return true
            }
        }
        emit(KeyOut.Text(added.joinToString("")))
        if (mods.isNotEmpty()) consumeOneShot()
        return false
    }

    private fun chord(keyCode: Int, modifiers: List<Int>) {
        // Shift first, then Ctrl/Alt/Meta; released in reverse.
        val mods = modifiers.distinct().sortedBy { if (it == KeyCodes.SHIFT_LEFT) 0 else 1 }
        mods.forEach { emit(KeyOut.Key(it, true)) }
        emit(KeyOut.Key(keyCode, true))
        emit(KeyOut.Key(keyCode, false))
        mods.asReversed().forEach { emit(KeyOut.Key(it, false)) }
    }

    private fun activeModifiers(): List<Int> =
        StickyModifier.entries.filter { it in armed || it in locked }.map { it.keyCode }

    private fun notifyModifiers() = onModifiersChanged?.invoke(armed.toSet(), locked.toSet())

    companion object {
        private const val MAX_DELETE = 256

        private fun normalize(text: CharSequence): String = text.toString().replace("\r\n", "\n").replace('\r', '\n')

        /** User-perceived characters (an emoji with skin tone is one), the unit a host backspace removes. */
        fun graphemes(s: String): List<String> {
            if (s.isEmpty()) return emptyList()
            val it = BreakIterator.getCharacterInstance()
            it.setText(s)
            val out = ArrayList<String>()
            var start = it.first()
            var end = it.next()
            while (end != BreakIterator.DONE) {
                out.add(s.substring(start, end))
                start = end
                end = it.next()
            }
            return out
        }
    }
}
