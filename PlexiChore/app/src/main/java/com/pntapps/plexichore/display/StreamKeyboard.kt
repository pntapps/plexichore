package com.pntapps.plexichore.display

import android.annotation.SuppressLint
import android.content.Context
import android.os.SystemClock
import android.text.InputType
import android.view.InputDevice
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.CompletionInfo
import android.view.inputmethod.CorrectionInfo
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.ExtractedText
import android.view.inputmethod.ExtractedTextRequest
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import androidx.compose.runtime.mutableStateOf

/**
 * Keyboard input for the stream screen: the system IME through an invisible [KeySinkView], the sticky
 * modifiers of the extra-keys row, and physical keyboards. Everything ends up as KEY messages
 * (PROTOCOL.md 0x05) through [send]. Main thread only.
 */
internal class StreamKeyboard(
    context: Context,
    private val send: (action: String, keyCode: Int, text: String?) -> Unit,
    private val isStreaming: () -> Boolean,
) {
    /** Keyboard requested open (button / bubble), observed by the overlay. */
    val open = mutableStateOf(false)
    val armed = mutableStateOf<Set<StickyModifier>>(emptySet())
    val locked = mutableStateOf<Set<StickyModifier>>(emptySet())

    /** Called when the keyboard opens or closes (video shift, overlay). */
    var onOpenChanged: ((Boolean) -> Unit)? = null

    private val imm = context.getSystemService(InputMethodManager::class.java)

    val translator = KeyboardTranslator { out ->
        when (out) {
            is KeyOut.Text -> send("down", 0, out.text)
            is KeyOut.Key -> send(if (out.down) "down" else "up", out.keyCode, null)
        }
    }.apply {
        onModifiersChanged = { a, l -> armed.value = a; locked.value = l }
        onImeResetNeeded = { sink.post { imm?.restartInput(sink) } }
    }

    val sink = KeySinkView(context, this)

    /** IME visible according to the window insets (API 30+; null = unknown). */
    private var imeVisible: Boolean? = null
    private var ignoreImeHideUntil = 0L
    private val heldHardware = LinkedHashSet<Int>()

    fun toggle() = if (open.value) hide() else show()

    fun show() {
        if (!isStreaming()) return
        if (!open.value) {
            open.value = true
            onOpenChanged?.invoke(true)
        }
        // A hide reported while the IME is still on its way in must not close us again.
        ignoreImeHideUntil = SystemClock.uptimeMillis() + SHOW_GRACE_MS
        sink.isFocusable = true
        sink.isFocusableInTouchMode = true
        sink.requestFocus()
        sink.post {
            if (!open.value) return@post
            sink.requestFocus()
            imm?.showSoftInput(sink, 0)
        }
    }

    fun hide() {
        val wasOpen = open.value
        open.value = false
        translator.reset()
        imm?.hideSoftInputFromWindow(sink.windowToken, 0)
        sink.clearFocus()
        sink.isFocusableInTouchMode = false
        sink.isFocusable = false
        if (wasOpen) onOpenChanged?.invoke(false)
    }

    /** Window insets changed (API 30+). */
    fun onImeVisibilityChanged(visible: Boolean) {
        val was = imeVisible
        imeVisible = visible
        if (!visible && was == true && open.value && SystemClock.uptimeMillis() > ignoreImeHideUntil) {
            hide() // the IME's own hide key / Back
        }
    }

    /** Rotation / resize without recreation: the IME may be re-laid out or dropped; bring it back. */
    fun onConfigurationChanged() {
        if (!open.value) return
        ignoreImeHideUntil = SystemClock.uptimeMillis() + SHOW_GRACE_MS
        sink.postDelayed({ if (open.value && imeVisible != true) show() }, 350)
    }

    /** Session ended (hosts release their own held keys on disconnect). */
    fun onSessionEnded() {
        heldHardware.clear()
        hide()
    }

    // ---- Extra-keys row ------------------------------------------------------------------

    fun press(keyCode: Int, consume: Boolean) {
        if (!isStreaming()) return
        translator.press(keyCode, consume = consume)
    }

    fun release() = translator.consumeOneShot()

    fun toggleModifier(m: StickyModifier) = translator.toggleModifier(m)

    // ---- IME raw key events --------------------------------------------------------------

    fun onImeKeyEvent(e: KeyEvent) {
        if (!isStreaming()) return
        if (e.action == KeyEvent.ACTION_MULTIPLE && e.keyCode == KeyEvent.KEYCODE_UNKNOWN) {
            e.characters?.let(translator::commitText)
            return
        }
        if (e.action != KeyEvent.ACTION_DOWN) return // a full press is sent on down
        val code = e.keyCode
        val modified = e.isCtrlPressed || e.isAltPressed || e.isMetaPressed
        val uc = e.getUnicodeChar(e.metaState)
        if (uc > 0 && !modified && code != KeyEvent.KEYCODE_ENTER && code != KeyEvent.KEYCODE_TAB &&
            code != KeyEvent.KEYCODE_DEL && code != KeyEvent.KEYCODE_FORWARD_DEL
        ) {
            // A character sent as a key event (some IMEs do for digits / password fields): type it as
            // text so the host's keyboard layout cannot change it.
            translator.commitText(String(Character.toChars(uc)))
            return
        }
        if (!isForwardable(code) || isModifierKey(code)) return
        translator.imeKey(code, shift = e.isShiftPressed)
    }

    // ---- Physical keyboards --------------------------------------------------------------

    /**
     * Forwards a key from a physical keyboard as a raw KEY down/up (key codes, so shortcuts work).
     * Returns false for anything else (volume, power, the navigation bar's Back, gamepads…).
     */
    fun onHardwareKey(e: KeyEvent): Boolean {
        if (!isStreaming()) return false
        val dev = e.device ?: return false
        if (dev.isVirtual || !e.isFromSource(InputDevice.SOURCE_KEYBOARD)) return false
        if (dev.keyboardType != InputDevice.KEYBOARD_TYPE_ALPHABETIC) return false
        val code = e.keyCode
        if (!isForwardable(code)) return false
        when (e.action) {
            KeyEvent.ACTION_DOWN -> {
                heldHardware.add(code)
                send("down", code, null)
            }
            KeyEvent.ACTION_UP -> {
                heldHardware.remove(code)
                send("up", code, null)
            }
        }
        return true
    }

    /** Window lost focus / paused: a key held now would never see its "up". */
    fun releaseHardwareKeys() {
        if (heldHardware.isEmpty()) return
        val keys = heldHardware.toList()
        heldHardware.clear()
        if (isStreaming()) keys.asReversed().forEach { send("up", it, null) }
    }

    companion object {
        private const val SHOW_GRACE_MS = 700L

        /** Key codes both hosts (or at least the Mac host) map; anything else stays local. */
        private val FORWARDABLE: Set<Int> = buildSet {
            addAll(7..16); addAll(29..54); addAll(131..142); addAll(19..22)
            addAll(listOf(61, 62, 66, 67, 111, 112, 122, 123, 92, 93, 124))
            addAll(listOf(59, 60, 113, 114, 57, 58, 117, 118, 115, 119))
            addAll(listOf(55, 56, 68, 69, 70, 71, 72, 73, 74, 75, 76))
            addAll(143..158); addAll(listOf(160, 161))
        }
        private val MODIFIERS = setOf(59, 60, 113, 114, 57, 58, 117, 118, 115, 119)

        fun isForwardable(code: Int) = code in FORWARDABLE
        fun isModifierKey(code: Int) = code in MODIFIERS
    }
}

/**
 * Invisible 1 px editor that the IME types into. Nothing is ever stored: every edit is translated
 * into KEY messages right away (see [KeyboardTranslator]).
 */
@SuppressLint("ViewConstructor")
internal class KeySinkView(context: Context, private val keyboard: StreamKeyboard) : View(context) {

    init {
        isFocusable = false
        isFocusableInTouchMode = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        alpha = 0f
    }

    override fun onCheckIsTextEditor(): Boolean = true

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS or
            InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN or EditorInfo.IME_ACTION_NONE
        outAttrs.initialSelStart = 0
        outAttrs.initialSelEnd = 0
        return SinkConnection()
    }

    /** Physical keys reach the IME before the activity while we hold focus: take them first. */
    override fun dispatchKeyEventPreIme(event: KeyEvent): Boolean =
        keyboard.onHardwareKey(event) || super.dispatchKeyEventPreIme(event)

    private inner class SinkConnection : BaseInputConnection(this, false) {
        private val t get() = keyboard.translator

        override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
            if (text != null) t.commitText(text)
            return true
        }

        override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean {
            t.setComposingText(text ?: "")
            return true
        }

        override fun finishComposingText(): Boolean {
            t.finishComposingText()
            return true
        }

        override fun setComposingRegion(start: Int, end: Int): Boolean = false // we expose no text to re-compose

        override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
            t.deleteSurroundingText(beforeLength, afterLength)
            return true
        }

        override fun deleteSurroundingTextInCodePoints(beforeLength: Int, afterLength: Int): Boolean {
            t.deleteSurroundingText(beforeLength, afterLength)
            return true
        }

        override fun sendKeyEvent(event: KeyEvent): Boolean {
            keyboard.onImeKeyEvent(event)
            return true
        }

        override fun performEditorAction(actionCode: Int): Boolean {
            t.editorAction()
            return true
        }

        override fun commitCompletion(text: CompletionInfo?): Boolean {
            text?.text?.let(t::commitText)
            return true
        }

        override fun commitCorrection(correctionInfo: CorrectionInfo?): Boolean = true // commitText follows

        override fun getTextBeforeCursor(length: Int, flags: Int): CharSequence = ""
        override fun getTextAfterCursor(length: Int, flags: Int): CharSequence = ""
        override fun getSelectedText(flags: Int): CharSequence? = null
        override fun getExtractedText(request: ExtractedTextRequest?, flags: Int): ExtractedText? = null

        override fun closeConnection() {
            t.finishComposingText()
            super.closeConnection()
        }
    }
}
