package com.pntapps.plexichore.ui.components

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.util.lerp
import androidx.compose.ui.geometry.lerp
import androidx.compose.ui.graphics.lerp
import android.provider.Settings
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.foundation.layout.Spacer
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.platform.LocalContext
import com.pntapps.plexichore.core.DisplayMode
import kotlin.math.cos
import kotlin.math.roundToInt
import androidx.compose.ui.unit.dp
import com.pntapps.plexichore.ui.theme.PlexiColors
import com.pntapps.plexichore.ui.theme.Plexi
import kotlin.math.PI
import kotlin.math.sin

/* ================================================================ device primitives */

private fun bodyColor(c: PlexiColors) = if (c.isDark) Color(0xFF1A2146) else Color(0xFFFFFFFF)
private fun bezelColor(c: PlexiColors) = if (c.isDark) Color(0xFF070A16) else Color(0xFF151A33)

private fun DrawScope.screenFill(c: PlexiColors, r: Rect, corner: Float) {
    drawRoundRect(
        Brush.linearGradient(listOf(Color(0xFF1B1446), Color(0xFF0B1F45)), r.topLeft, r.bottomRight),
        r.topLeft, r.size, CornerRadius(corner),
    )
    drawRoundRect(
        Brush.radialGradient(listOf(c.accentStart.copy(alpha = 0.55f), Color.Transparent), Offset(r.left + r.width * 0.2f, r.top), r.width * 0.7f),
        r.topLeft, r.size, CornerRadius(corner),
    )
    drawRoundRect(
        Brush.radialGradient(listOf(c.accentEnd.copy(alpha = 0.40f), Color.Transparent), Offset(r.right, r.bottom), r.width * 0.6f),
        r.topLeft, r.size, CornerRadius(corner),
    )
}

/** Draws a laptop whose display area is [screen]; returns nothing, screen content drawn by caller. */
private fun DrawScope.drawLaptop(c: PlexiColors, screen: Rect, u: Float) {
    val bezel = 1.4f * u
    val outer = Rect(screen.left - bezel, screen.top - bezel, screen.right + bezel, screen.bottom + bezel * 1.6f)
    // shadow
    drawOval(Color.Black.copy(alpha = if (c.isDark) 0.45f else 0.12f), Offset(outer.left - 2 * u, outer.bottom + 3.2f * u), Size(outer.width + 4 * u, 3.4f * u))
    drawRoundRect(bezelColor(c), outer.topLeft, outer.size, CornerRadius(2.2f * u))
    drawRoundRect(Color.White.copy(alpha = 0.10f), outer.topLeft, outer.size, CornerRadius(2.2f * u), style = Stroke(0.25f * u))
    screenFill(c, screen, 0.6f * u)
    // base / keyboard deck
    val baseTop = outer.bottom
    val base = Path().apply {
        moveTo(outer.left - 3.5f * u, baseTop + 0.2f * u)
        lineTo(outer.right + 3.5f * u, baseTop + 0.2f * u)
        lineTo(outer.right + 1.2f * u, baseTop + 3.2f * u)
        lineTo(outer.left - 1.2f * u, baseTop + 3.2f * u)
        close()
    }
    drawPath(base, Brush.verticalGradient(listOf(bodyColor(c), bodyColor(c).copy(alpha = 0.75f)), baseTop, baseTop + 3.2f * u))
    drawPath(base, Color.White.copy(alpha = if (c.isDark) 0.12f else 0.6f), style = Stroke(0.2f * u))
    drawRoundRect(Color.Black.copy(alpha = 0.25f), Offset(outer.center.x - 5 * u, baseTop + 0.2f * u), Size(10 * u, 0.8f * u), CornerRadius(0.4f * u))
}

private fun DrawScope.drawTablet(c: PlexiColors, screen: Rect, u: Float, stand: Boolean = true) {
    val bezel = 1.3f * u
    val outer = Rect(screen.left - bezel, screen.top - bezel, screen.right + bezel, screen.bottom + bezel)
    if (stand) {
        val p = Path().apply {
            moveTo(outer.center.x - 2f * u, outer.bottom - 2 * u)
            lineTo(outer.center.x + 6f * u, outer.bottom + 4.0f * u)
            lineTo(outer.center.x + 3f * u, outer.bottom + 4.0f * u)
            lineTo(outer.center.x - 4f * u, outer.bottom - 2 * u)
            close()
        }
        drawPath(p, bodyColor(c).copy(alpha = 0.9f))
        drawOval(Color.Black.copy(alpha = if (c.isDark) 0.45f else 0.12f), Offset(outer.left, outer.bottom + 3.3f * u), Size(outer.width, 2.4f * u))
    }
    drawRoundRect(bezelColor(c), outer.topLeft, outer.size, CornerRadius(2.6f * u))
    drawRoundRect(
        Brush.linearGradient(listOf(c.accentStart.copy(alpha = 0.9f), c.accentEnd.copy(alpha = 0.9f)), outer.topLeft, outer.bottomRight),
        outer.topLeft, outer.size, CornerRadius(2.6f * u), style = Stroke(0.35f * u),
    )
    screenFill(c, screen, 1.2f * u)
    drawCircle(Color.White.copy(alpha = 0.18f), 0.35f * u, Offset(outer.center.x, outer.top + bezel / 2))
}

private val windowDots = arrayOf(Color(0xFFFF6B7A), Color(0xFFFBBF24), Color(0xFF34D399))
private val windowBars = floatArrayOf(0.35f, 0.55f, 0.42f, 0.75f, 0.62f)

/** An app window with a bar chart; a non-zero [barPhase] (radians) makes the bars breathe. */
private fun DrawScope.drawWindow(c: PlexiColors, r: Rect, u: Float, alpha: Float, barPhase: Float = 0f) {
    if (alpha <= 0.01f) return
    val cr = CornerRadius(0.9f * u)
    drawRoundRect(c.accentStart, Offset(r.left - 0.6f * u, r.top - 0.4f * u), Size(r.width + 1.2f * u, r.height + 1.4f * u), CornerRadius(1.4f * u), alpha = 0.35f * alpha)
    drawRoundRect(Color(0xFFF4F6FF), r.topLeft, r.size, cr, alpha = 0.96f * alpha)
    val bar = r.height * 0.16f
    drawRoundRect(Color(0xFFE2E6F5), r.topLeft, Size(r.width, bar), cr, alpha = alpha)
    for (i in windowDots.indices) {
        drawCircle(windowDots[i], bar * 0.22f, Offset(r.left + bar * (0.6f + i * 0.6f), r.top + bar / 2), alpha = alpha)
    }
    // content lines + chart bars
    val pad = r.width * 0.08f
    val top = r.top + bar + pad * 0.8f
    drawRoundRect(c.accentStart, Offset(r.left + pad, top), Size(r.width * 0.45f, r.height * 0.07f), CornerRadius(u), alpha = 0.85f * alpha)
    drawRoundRect(Color(0xFFC8CEE6), Offset(r.left + pad, top + r.height * 0.13f), Size(r.width * 0.32f, r.height * 0.05f), CornerRadius(u), alpha = alpha)
    val chartBottom = r.bottom - pad * 0.8f
    val bw = (r.width - 2 * pad) / (windowBars.size * 1.6f)
    for (i in windowBars.indices) {
        val wobble = if (barPhase == 0f) 1f else 0.82f + 0.18f * sin(barPhase + i * 1.3f)
        val bh = r.height * 0.4f * windowBars[i] * wobble
        drawRoundRect(
            lerp(c.accentStart, c.accentEnd, i / (windowBars.size - 1f)),
            Offset(r.left + pad + i * bw * 1.6f, chartBottom - bh), Size(bw, bh), CornerRadius(0.3f * u), alpha = alpha,
        )
    }
}

/* ================================================================ Hero */

/*
 * Mode-aware hero: a laptop + tablet whose screen content tells what the selected display mode
 * does. Everything lives in normalised screen coordinates (0..1 of a screen rect) so the same
 * element can sit on either device (Mirror = same normalised layout on both) or travel between
 * them (Extend / Primary). Mode switches blend three weights (ext/pri/mir, sum = 1) with a 520 ms
 * tween; idle motion comes from one infinite transition. Phase 0 of every loop is a meaningful
 * still frame (used for reduced motion and in screenshot tests, where infinite animations are off).
 */

private const val HERO_LOOP_MS = 6500
private val heroModeSpec = tween<Float>(520, easing = FastOutSlowInEasing)

// Normalised layouts (fractions of a screen rect).
private val nWindowA = Rect(0.12f, 0.14f, 0.56f, 0.80f) // "chart" window on the laptop / mirrored copy
private val nWindowATab = Rect(0.17f, 0.10f, 0.90f, 0.82f) // same window when it lives on the tablet
private val nWindowB = Rect(0.60f, 0.10f, 0.94f, 0.62f) // laptop's own "doc" window
private val nTaskbar = Rect(0.30f, 0.895f, 0.70f, 0.965f)
private const val N_ICON_X = 0.035f
private const val N_ICON_Y = 0.08f
private const val N_ICON_SIZE = 0.05f

private val dockDots = arrayOf(Color(0xFF7C5CFF), Color(0xFF22D3EE), Color(0xFFFBBF24), Color(0xFF34D399), Color(0xFFFF6B7A))
private val iconColors = arrayOf(Color(0xFF7C5CFF), Color(0xFF22D3EE), Color(0xFFFBBF24))

/** Extend loop: 0 = window on the tablet (still frame), fade back to the laptop, glide across again. */
private fun extTravel(p: Float): Float = when {
    p < 0.50f -> 1f
    p < 0.66f -> 0f
    p < 0.94f -> FastOutSlowInEasing.transform((p - 0.66f) / 0.28f)
    else -> 1f
}

private fun extAlpha(p: Float): Float = when {
    p < 0.40f -> 1f
    p < 0.50f -> 1f - (p - 0.40f) / 0.10f
    p < 0.58f -> (p - 0.50f) / 0.08f
    else -> 1f
}

private fun Rect.at(fx: Float, fy: Float) = Offset(left + width * fx, top + height * fy)
private fun Rect.sub(n: Rect) = Rect(left + width * n.left, top + height * n.top, left + width * n.right, top + height * n.bottom)

/** Cached, allocation-free-per-frame drawing state for the hero. */
private class HeroCache(c: PlexiColors, val u: Float, val laptop: ImageBitmap, val tablet: ImageBitmap) {
    val laptopScreen = Rect(6 * u, 12 * u, 58 * u, 44 * u)
    val tabletScreen0 = Rect(67 * u, 23 * u, 95 * u, 41.5f * u)
    val beamStart = Offset(52 * u, 10 * u)
    val beamCtrl = Offset(68 * u, -2 * u)
    val beamEnd = Offset(80 * u, 20 * u)
    val beam = Path().apply { moveTo(beamStart.x, beamStart.y); quadraticTo(beamCtrl.x, beamCtrl.y, beamEnd.x, beamEnd.y) }
    val beamBrush = Brush.linearGradient(listOf(c.accentStart.copy(alpha = 0f), c.accentStart.copy(alpha = 0.5f), c.accentEnd.copy(alpha = 0.6f)), beamStart, beamEnd)
    val beamStroke = Stroke(0.35f * u, cap = StrokeCap.Round, pathEffect = PathEffect.dashPathEffect(floatArrayOf(0.6f * u, 1.6f * u)))

    /** The desktop plane continuing across the gap (Extend). */
    val band = Path().apply {
        moveTo(57 * u, 13.5f * u)
        lineTo(68 * u, 24.5f * u)
        lineTo(68 * u, 40 * u)
        lineTo(57 * u, 42.5f * u)
        close()
    }
    val bandBrush = Brush.horizontalGradient(listOf(c.accentStart.copy(alpha = 0.55f), c.accentEnd.copy(alpha = 0.55f)), 57 * u, 68 * u)
    val edgeBrushL = Brush.verticalGradient(listOf(Color.Transparent, c.accentStart, Color.Transparent), laptopScreen.top, laptopScreen.bottom)
    val edgeBrushT = Brush.verticalGradient(listOf(Color.Transparent, c.accentEnd, Color.Transparent), tabletScreen0.top, tabletScreen0.bottom)

    /** Halo behind the tablet when it is the main screen (drawn translated by the bob). */
    val halo = Brush.radialGradient(listOf(c.accentStart.copy(alpha = 0.55f), c.accentEnd.copy(alpha = 0.18f), Color.Transparent), tabletScreen0.center, 26 * u)
    val badgeBrush = Brush.linearGradient(listOf(Color(0xFFFBBF24), Color(0xFFFF8A4C)), Offset(-1f, -1f), Offset(1f, 1f))

    /** Unit-sized shapes, drawn with translate + scale. */
    val cursor = Path().apply {
        moveTo(0f, 0f); lineTo(0f, 3.6f); lineTo(1.0f, 2.7f); lineTo(1.8f, 4.2f)
        lineTo(2.4f, 3.9f); lineTo(1.7f, 2.5f); lineTo(2.9f, 2.5f); close()
    }
    val cursorStroke = Stroke(0.22f)
    val star = Path().apply {
        for (i in 0 until 10) {
            val r = if (i % 2 == 0) 1f else 0.45f
            val a = -PI / 2 + i * PI / 5
            val x = (cos(a) * r).toFloat(); val y = (sin(a) * r).toFloat()
            if (i == 0) moveTo(x, y) else lineTo(x, y)
        }
        close()
    }
    val chevron = Path().apply { moveTo(-0.5f, -1f); lineTo(0.5f, 0f); lineTo(-0.5f, 1f) }
    val chevronStroke = Stroke(0.45f, cap = StrokeCap.Round, join = StrokeJoin.Round)
    val thin = Stroke(0.3f * u)
    val ghostStroke = Stroke(0.35f * u)
    val outline = Stroke(0.5f * u)
    val dimColor = Color(0xFF04060F)
}

/**
 * Laptop + tablet illustrating [mode]: Extend (a window glides across onto the tablet, the desktop
 * continues to the right), Primary (taskbar, icons and the "main" star move to the tablet, the
 * laptop dims) or Mirror (both screens show the same, moving in sync).
 */
@Composable
fun HeroIllustration(modifier: Modifier = Modifier, mode: DisplayMode = DisplayMode.EXTEND) {
    val c = Plexi.colors
    val context = LocalContext.current
    val reduceMotion = remember {
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
    val time: State<Float> = if (reduceMotion) {
        remember { mutableFloatStateOf(0f) }
    } else {
        rememberInfiniteTransition(label = "hero")
            .animateFloat(0f, 1f, infiniteRepeatable(tween(HERO_LOOP_MS, easing = LinearEasing)), label = "t")
    }
    val spec = if (reduceMotion) snap() else heroModeSpec
    val wExt = animateFloatAsState(if (mode == DisplayMode.EXTEND) 1f else 0f, spec, label = "ext")
    val wPri = animateFloatAsState(if (mode == DisplayMode.PRIMARY) 1f else 0f, spec, label = "pri")
    val wMir = animateFloatAsState(if (mode == DisplayMode.MIRROR) 1f else 0f, spec, label = "mir")

    // Entering Extend replays the glide right away (window on the laptop, then across).
    val extOffset = remember { mutableFloatStateOf(0f) }
    var prevMode by remember { mutableStateOf(mode) }
    LaunchedEffect(mode) {
        if (mode != prevMode) {
            if (mode == DisplayMode.EXTEND && !reduceMotion) {
                val start = if (prevMode == DisplayMode.PRIMARY) 0.40f else 0.60f
                extOffset.floatValue = start - time.value
            }
            prevMode = mode
        }
    }

    Spacer(
        modifier.aspectRatio(100f / 62f).drawWithCache {
            val u = size.width / 100f
            val w = size.width.roundToInt().coerceAtLeast(1)
            val h = size.height.roundToInt().coerceAtLeast(1)
            // Device frames never change: render them once into bitmaps.
            val lap = ImageBitmap(w, h)
            val tab = ImageBitmap(w, h)
            val scope = CanvasDrawScope()
            val laptopScreen = Rect(6 * u, 12 * u, 58 * u, 44 * u)
            val tabletScreen = Rect(67 * u, 23 * u, 95 * u, 41.5f * u)
            scope.draw(this, layoutDirection, androidx.compose.ui.graphics.Canvas(lap), size) { drawLaptop(c, laptopScreen, u) }
            scope.draw(this, layoutDirection, androidx.compose.ui.graphics.Canvas(tab), size) { drawTablet(c, tabletScreen, u) }
            val k = HeroCache(c, u, lap, tab)
            onDrawBehind {
                drawHero(c, k, time.value, extOffset.floatValue, wExt.value, wPri.value, wMir.value)
            }
        },
    )
}

private fun DrawScope.drawHero(c: PlexiColors, k: HeroCache, t: Float, extOffset: Float, ext0: Float, pri0: Float, mir0: Float) {
    val u = k.u
    val sum = (ext0 + pri0 + mir0).coerceAtLeast(0.0001f)
    val ext = ext0 / sum; val pri = pri0 / sum; val mir = mir0 / sum
    val tau = (2 * PI).toFloat()
    val dy = sin(t * tau * 1.25f) * 0.9f * u // tablet bob (1.25 cycles per loop keeps it seamless)
    val L = k.laptopScreen
    val T = k.tabletScreen0.translate(0f, dy)
    val p = ((t + extOffset) % 1f + 1f) % 1f // Extend loop phase
    val barPhase = t * tau * 2f
    // Mirror / Primary cursor path (normalised, figure-eight over the chart).
    val ca = t * tau * 2f
    val cnx = 0.24f + 0.2f * (0.5f + 0.5f * sin(ca))
    val cny = 0.56f + 0.1f * sin(2 * ca)

    // ---- behind the devices
    if (pri > 0f) translate(0f, dy) { drawCircle(k.halo, 26 * u, k.tabletScreen0.center, alpha = pri) }
    if (ext > 0f) {
        drawPath(k.band, k.bandBrush, alpha = 0.55f * ext)
    }
    drawPath(k.beam, k.beamBrush, style = k.beamStroke)
    for (i in 0 until 4) {
        val q = ((t * 2f) + i / 4f) % 1f
        val pt = quad(k.beamStart, k.beamCtrl, k.beamEnd, q)
        val a = sin(q * PI).toFloat() * (1f - 0.6f * mir)
        drawCircle(c.accentEnd.copy(alpha = 0.25f * a), 1.4f * u, pt)
        drawCircle(Color.White.copy(alpha = 0.9f * a), 0.45f * u, pt)
    }

    // ---- devices
    drawImage(k.laptop)
    translate(0f, dy) { drawImage(k.tablet) }

    // ---- laptop's own content (Extend: its own windows; Primary: dimmed leftovers)
    val bAlpha = ext + pri * 0.8f
    clipRect(L.left, L.top, L.right, L.bottom) {
        if (bAlpha > 0.01f) drawDocWindow(c, L.sub(nWindowB), u, bAlpha)
        if (pri > 0f) drawRect(k.dimColor, L.topLeft, L.size, alpha = 0.62f * pri)
    }

    // ---- mirrored copy on the tablet (identical layout, same animation phase)
    if (mir > 0.01f) clipRect(T.left, T.top, T.right, T.bottom) {
        drawIcons(T.at(N_ICON_X, N_ICON_Y), T.width * N_ICON_SIZE, mir)
        drawTaskbar(T.sub(nTaskbar), mir)
        drawWindow(c, T.sub(nWindowA), u * T.width / L.width, mir, barPhase)
        drawCursorAt(k, T.at(cnx, cny), u * 0.7f, mir)
    }

    // ---- desktop elements that travel (Primary moves them to the tablet)
    val lift = sin(pri * PI).toFloat() * 3.5f * u
    run {
        val o = lerp(L.at(N_ICON_X, N_ICON_Y), T.at(N_ICON_X, N_ICON_Y), pri)
        drawIcons(Offset(o.x, o.y - lift), lerp(L.width, T.width, pri) * N_ICON_SIZE, 1f)
        val bar = lerp(L.sub(nTaskbar), T.sub(nTaskbar), pri).translate(0f, -lift)
        drawTaskbar(bar, 1f)
    }

    // ---- window A: Extend glides it across, Primary keeps it on the tablet, Mirror on the laptop
    val s = ext * extTravel(p) + pri
    val aAlpha = ext * extAlpha(p) + pri + mir
    val aLift = sin(s * PI).toFloat() * 4 * u
    val a = lerp(L.sub(nWindowA), T.sub(nWindowATab), s).translate(0f, -aLift)
    clipRect(L.left, 0f, T.right, size.height) {
        drawWindow(c, a, u * lerp(1f, 0.75f, s), aAlpha, barPhase)
    }
    // cursor: grabs A in Extend, roams the main screen otherwise
    val grab = Offset(a.left + a.width * 0.55f, a.top + a.height * 0.09f)
    val roam = lerp(L.at(cnx, cny), T.at(cnx, cny), pri / (pri + mir).coerceAtLeast(0.0001f))
    val cur = lerp(roam, grab, ext)
    val curScale = lerp(lerp(1f, 0.7f, pri / (pri + mir).coerceAtLeast(0.0001f)), lerp(1f, 0.8f, s), ext)
    drawCursorAt(k, cur, u * curScale, ext * extAlpha(p) + pri + mir)

    // ---- Extend: "the desktop continues" chevrons + glowing inner edges
    if (ext > 0.01f) {
        drawRect(k.edgeBrushL, Offset(L.right - 0.35f * u, L.top), Size(0.35f * u, L.height), alpha = 0.9f * ext)
        translate(0f, dy) { drawRect(k.edgeBrushT, Offset(k.tabletScreen0.left, k.tabletScreen0.top), Size(0.35f * u, k.tabletScreen0.height), alpha = 0.9f * ext) }
        val cy = 31.5f * u + dy * 0.5f
        for (i in 0 until 3) {
            val q = ((t * 3f) + i / 3f) % 1f
            val x = lerp(60.2f * u, 65f * u, q)
            val al = sin(q * PI).toFloat() * ext
            withTransform({ translate(x, cy); scale(1.1f * u, 1.1f * u, Offset.Zero) }) {
                drawPath(k.chevron, Color.White, alpha = al, style = k.chevronStroke)
            }
        }
    }

    // ---- Mirror: a "copy" of the screen travels along the beam and lands on the tablet
    if (mir > 0.01f) {
        val q = ((t * 2f) + 0.45f) % 1f
        val travel = (q / 0.75f).coerceIn(0f, 1f)
        if (q < 0.75f) {
            val pt = quad(k.beamStart, k.beamCtrl, k.beamEnd, travel)
            val gw = lerp(9f, 6f, travel) * u; val gh = gw * 0.62f
            val al = sin(travel * PI).toFloat().coerceAtLeast(0f) * mir
            drawRoundRect(c.accentEnd, Offset(pt.x - gw / 2, pt.y - gh / 2), Size(gw, gh), CornerRadius(0.8f * u), alpha = 0.18f * al)
            drawRoundRect(Color.White, Offset(pt.x - gw / 2, pt.y - gh / 2), Size(gw, gh), CornerRadius(0.8f * u), alpha = 0.85f * al, style = k.ghostStroke)
        }
        // landing pulse around the tablet screen
        val land = ((q - 0.7f) / 0.3f).coerceIn(0f, 1f)
        if (land > 0f) {
            val grow = land * 1.6f * u
            drawRoundRect(c.accentEnd, Offset(T.left - grow, T.top - grow), Size(T.width + 2 * grow, T.height + 2 * grow), CornerRadius(1.2f * u + grow),
                alpha = (1f - land) * 0.9f * mir, style = k.outline)
        }
    }

    // ---- "Main screen" star badge: laptop corner -> tablet corner in Primary
    run {
        val from = Offset(L.right - 0.6f * u, L.top + 0.4f * u)
        val to = Offset(T.right - 0.4f * u, T.top + 0.2f * u)
        val o = lerp(from, to, pri)
        val bo = Offset(o.x, o.y - sin(pri * PI).toFloat() * 6 * u)
        val r = lerp(1.7f, 2.4f, pri) * u
        val pulse = 0.5f + 0.5f * sin(t * tau * 2f)
        drawCircle(Color(0xFFFBBF24), r * (1.6f + 0.35f * pulse), bo, alpha = 0.22f * pri)
        drawCircle(Color.Black, r * 1.05f, Offset(bo.x, bo.y + 0.3f * u), alpha = 0.35f)
        withTransform({ translate(bo.x, bo.y); scale(r, r, Offset.Zero) }) {
            drawCircle(k.badgeBrush, 1f, Offset.Zero)
            drawPath(k.star, Color.White, alpha = 0.95f)
        }
        drawCircle(Color.White, r, bo, alpha = 0.35f, style = Stroke(0.22f * u))
    }
}

private fun DrawScope.drawIcons(origin: Offset, s: Float, alpha: Float) {
    for (i in 0 until 3) {
        val y = origin.y + i * s * 1.55f
        drawRoundRect(iconColors[i], Offset(origin.x, y), Size(s, s), CornerRadius(s * 0.28f), alpha = 0.9f * alpha)
        drawRoundRect(Color.White, Offset(origin.x + s * 0.25f, y + s * 0.25f), Size(s * 0.5f, s * 0.5f), CornerRadius(s * 0.12f), alpha = 0.55f * alpha)
    }
}

private fun DrawScope.drawTaskbar(r: Rect, alpha: Float) {
    drawRoundRect(Color.White, r.topLeft, r.size, CornerRadius(r.height / 2), alpha = 0.18f * alpha)
    val step = r.width / 5.6f
    for (i in 0 until 5) {
        drawCircle(dockDots[i], r.height * 0.27f, Offset(r.left + step * (0.9f + i * 0.95f), r.center.y), alpha = 0.95f * alpha)
    }
}

/** A text/document window (the laptop's own content in Extend). */
private fun DrawScope.drawDocWindow(c: PlexiColors, r: Rect, u: Float, alpha: Float) {
    val cr = CornerRadius(0.9f * u)
    drawRoundRect(Color(0xFFEAF6FF), r.topLeft, r.size, cr, alpha = 0.94f * alpha)
    val bar = r.height * 0.16f
    drawRoundRect(c.accentEnd, r.topLeft, Size(r.width, bar), cr, alpha = 0.75f * alpha)
    val pad = r.width * 0.12f
    val lh = r.height * 0.065f
    for (i in 0 until 4) {
        val lw = (if (i == 3) 0.45f else 0.76f - i * 0.06f) * r.width
        drawRoundRect(Color(0xFF9AA6C8), Offset(r.left + pad, r.top + bar + pad + i * lh * 2.1f), Size(lw, lh), CornerRadius(lh / 2), alpha = alpha)
    }
}

private fun DrawScope.drawCursorAt(k: HeroCache, at: Offset, scale: Float, alpha: Float) {
    if (alpha <= 0.01f) return
    withTransform({ translate(at.x, at.y); scale(scale, scale, Offset.Zero) }) {
        drawPath(k.cursor, Color.White, alpha = alpha)
        drawPath(k.cursor, Color.Black, alpha = 0.7f * alpha, style = k.cursorStroke)
    }
}

private fun quad(a: Offset, c: Offset, b: Offset, t: Float): Offset {
    val m = 1 - t
    return Offset(m * m * a.x + 2 * m * t * c.x + t * t * b.x, m * m * a.y + 2 * m * t * c.y + t * t * b.y)
}

/* ================================================================ Radar */

@Composable
fun RadarScanner(modifier: Modifier = Modifier, blips: Int = 0) {
    val c = Plexi.colors
    val inf = rememberInfiniteTransition(label = "radar")
    val sweep by inf.animateFloat(0f, 360f, infiniteRepeatable(tween(3200, easing = LinearEasing)), label = "sweep")
    val pulse by inf.animateFloat(0f, 1f, infiniteRepeatable(tween(2400, easing = LinearEasing)), label = "pulse")
    Canvas(modifier.aspectRatio(1f)) {
        val center = this.center
        val maxR = size.minDimension / 2
        // static rings
        for (i in 1..3) drawCircle(c.textTertiary.copy(alpha = 0.18f), maxR * i / 3f, center, style = Stroke(1.dp.toPx()))
        drawLine(c.textTertiary.copy(alpha = 0.10f), Offset(center.x - maxR, center.y), Offset(center.x + maxR, center.y), 1.dp.toPx())
        drawLine(c.textTertiary.copy(alpha = 0.10f), Offset(center.x, center.y - maxR), Offset(center.x, center.y + maxR), 1.dp.toPx())
        // pulses
        for (k in 0 until 2) {
            val p = (pulse + k * 0.5f) % 1f
            drawCircle(c.accentEnd.copy(alpha = 0.45f * (1 - p)), maxR * p, center, style = Stroke(2.dp.toPx()))
        }
        // sweep
        rotate(sweep, center) {
            drawCircle(
                Brush.sweepGradient(
                    0f to Color.Transparent, 0.72f to Color.Transparent,
                    0.97f to c.accentStart.copy(alpha = 0.45f), 1f to c.accentEnd.copy(alpha = 0.8f),
                    center = center,
                ),
                maxR, center,
            )
            drawLine(Brush.linearGradient(listOf(c.accentEnd, Color.Transparent), center, Offset(center.x + maxR, center.y)),
                center, Offset(center.x + maxR, center.y), 2.dp.toPx(), cap = StrokeCap.Round)
        }
        // blips
        val spots = listOf(Offset(0.42f, -0.30f), Offset(-0.55f, 0.18f), Offset(0.15f, 0.62f))
        for (i in 0 until blips.coerceAtMost(3)) {
            val o = Offset(center.x + spots[i].x * maxR, center.y + spots[i].y * maxR)
            drawCircle(c.accentEnd.copy(alpha = 0.25f), 9.dp.toPx(), o)
            drawCircle(c.accentEnd, 4.dp.toPx(), o)
        }
        // center glyph: mini tablet
        val tw = maxR * 0.34f; val th = tw * 0.66f
        drawCircle(Brush.radialGradient(listOf(c.accentStart.copy(alpha = 0.55f), Color.Transparent), center, maxR * 0.45f), maxR * 0.45f, center)
        drawRoundRect(bezelColor(c), Offset(center.x - tw / 2, center.y - th / 2), Size(tw, th), CornerRadius(tw * 0.09f))
        drawRoundRect(c.accentBrush, Offset(center.x - tw / 2, center.y - th / 2), Size(tw, th), CornerRadius(tw * 0.09f), style = Stroke(1.5.dp.toPx()))
        drawRoundRect(Brush.linearGradient(listOf(c.accentStart.copy(alpha = 0.8f), c.accentEnd.copy(alpha = 0.7f))),
            Offset(center.x - tw / 2 + tw * 0.08f, center.y - th / 2 + tw * 0.08f), Size(tw * 0.84f, th - tw * 0.16f), CornerRadius(tw * 0.04f))
    }
}

/* ================================================================ Connection link */

/** Computer <-> tablet with traveling dots. [progress] null = indeterminate. */
@Composable
fun LinkIllustration(modifier: Modifier = Modifier, success: Boolean = false, error: Boolean = false) {
    val c = Plexi.colors
    val inf = rememberInfiniteTransition(label = "link")
    val t by inf.animateFloat(0f, 1f, infiniteRepeatable(tween(1600, easing = LinearEasing)), label = "t")
    val glow by inf.animateFloat(0.6f, 1f, infiniteRepeatable(tween(1200), RepeatMode.Reverse), label = "g")
    Canvas(modifier.aspectRatio(100f / 40f)) {
        val u = size.width / 100f
        drawLaptop(c, Rect(6 * u, 6 * u, 36 * u, 25 * u), u)
        drawTablet(c, Rect(66 * u, 9 * u, 94 * u, 26.5f * u), u)
        val y = 18 * u
        val a = Offset(40 * u, y); val b = Offset(62 * u, y)
        val col = when { error -> c.danger; success -> c.success; else -> c.accentEnd }
        drawLine(col.copy(alpha = 0.18f), a, b, 0.7f * u, cap = StrokeCap.Round)
        if (!error && !success) {
            for (i in 0 until 5) {
                val k = (t + i / 5f) % 1f
                val p = Offset(lerp(a.x, b.x, k), y)
                drawCircle(Brush.linearGradient(listOf(c.accentStart, c.accentEnd)), 0.75f * u * sin(k * PI).toFloat() + 0.2f * u, p)
            }
        } else {
            drawLine(col, a, b, 0.7f * u, cap = StrokeCap.Round)
            val m = Offset((a.x + b.x) / 2, y)
            drawCircle(col.copy(alpha = 0.25f * glow), 4.2f * u, m)
            drawCircle(col, 2.8f * u, m)
            if (success) {
                val p = Path().apply { moveTo(m.x - 1.3f * u, m.y); lineTo(m.x - 0.3f * u, m.y + 1.0f * u); lineTo(m.x + 1.4f * u, m.y - 1.0f * u) }
                drawPath(p, Color.White, style = Stroke(0.55f * u, cap = StrokeCap.Round))
            } else {
                drawLine(Color.White, Offset(m.x - u, m.y - u), Offset(m.x + u, m.y + u), 0.55f * u, StrokeCap.Round)
                drawLine(Color.White, Offset(m.x + u, m.y - u), Offset(m.x - u, m.y + u), 0.55f * u, StrokeCap.Round)
            }
        }
    }
}

/* ================================================================ Onboarding art */

/** USB cable + Wi-Fi waves joining a laptop and a tablet. */
@Composable
fun ConnectIllustration(modifier: Modifier = Modifier) {
    val c = Plexi.colors
    val inf = rememberInfiniteTransition(label = "connect")
    val t by inf.animateFloat(0f, 1f, infiniteRepeatable(tween(2200, easing = LinearEasing)), label = "t")
    Canvas(modifier.aspectRatio(100f / 62f)) {
        val u = size.width / 100f
        val laptop = Rect(6 * u, 18 * u, 50 * u, 45 * u)
        val tablet = Rect(64 * u, 26 * u, 94 * u, 45 * u)
        // cable
        val s = Offset(laptop.right + 4.8f * u, laptop.bottom + 3.2f * u)
        val e = Offset(tablet.center.x, tablet.bottom + 1.3f * u)
        val cable = Path().apply { moveTo(s.x, s.y); cubicTo(s.x + 2 * u, s.y + 9 * u, e.x - 2 * u, e.y + 11 * u, e.x, e.y) }
        drawPath(cable, Brush.linearGradient(listOf(c.accentStart, c.accentEnd), s, e), style = Stroke(0.9f * u, cap = StrokeCap.Round))
        drawPath(cable, Color.White.copy(alpha = 0.9f), style = Stroke(0.5f * u, cap = StrokeCap.Round, pathEffect = PathEffect.dashPathEffect(floatArrayOf(0.1f, 6f * u), -t * 6.1f * u)))
        drawLaptop(c, laptop, u)
        drawTablet(c, tablet, u, stand = false)
        // wifi arcs over the gap
        val wc = Offset(57 * u, 16 * u)
        for (i in 0 until 3) {
            val phase = ((t * 3f) - i).let { ((it % 3f) + 3f) % 3f } / 3f
            val a = 0.25f + 0.75f * (1f - phase)
            val r = (3.5f + i * 3.2f) * u
            drawArc(c.accentEnd.copy(alpha = a), 225f, 90f, false, Offset(wc.x - r, wc.y - r), Size(r * 2, r * 2), style = Stroke(1.1f * u, cap = StrokeCap.Round))
        }
        drawCircle(c.accentEnd, 1.1f * u, Offset(wc.x, wc.y + 0.4f * u))
        // labels as glyph dots on screens
        drawWindow(c, Rect(12 * u, 23 * u, 30 * u, 37 * u), u, 1f)
        drawWindow(c, Rect(70 * u, 29 * u, 88 * u, 42 * u), u, 0.85f)
    }
}

/** Bell with ripple rings. */
@Composable
fun NotificationIllustration(modifier: Modifier = Modifier) {
    val c = Plexi.colors
    val inf = rememberInfiniteTransition(label = "bell")
    val swing by inf.animateFloat(-12f, 12f, infiniteRepeatable(tween(900, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "s")
    val ripple by inf.animateFloat(0f, 1f, infiniteRepeatable(tween(2400, easing = LinearEasing)), label = "r")
    Canvas(modifier.aspectRatio(100f / 62f)) {
        val u = size.width / 100f
        val cx = 50 * u; val cy = 31 * u
        for (k in 0 until 3) {
            val p = (ripple + k / 3f) % 1f
            drawCircle(c.accentStart.copy(alpha = 0.35f * (1 - p)), (10 + p * 22) * u, Offset(cx, cy), style = Stroke(0.5f * u))
        }
        drawCircle(Brush.radialGradient(listOf(c.accentStart.copy(alpha = 0.45f), Color.Transparent), Offset(cx, cy), 18 * u), 18 * u, Offset(cx, cy))
        translate(0f, 0f) {
            rotate(swing, Offset(cx, cy - 11 * u)) {
                val bell = Path().apply {
                    moveTo(cx - 9 * u, cy + 6 * u)
                    cubicTo(cx - 7 * u, cy + 3 * u, cx - 8 * u, cy - 9 * u, cx, cy - 10 * u)
                    cubicTo(cx + 8 * u, cy - 9 * u, cx + 7 * u, cy + 3 * u, cx + 9 * u, cy + 6 * u)
                    close()
                }
                drawPath(bell, Brush.linearGradient(listOf(c.accentStart, c.accentEnd), Offset(cx - 9 * u, cy - 10 * u), Offset(cx + 9 * u, cy + 6 * u)))
                drawPath(bell, Color.White.copy(alpha = 0.3f), style = Stroke(0.35f * u))
                drawCircle(Color.White, 1.0f * u, Offset(cx, cy - 11 * u))
                drawCircle(Color.White.copy(alpha = 0.95f), 2.2f * u, Offset(cx + 0.5f * u, cy + 8.2f * u))
            }
        }
        // badge
        drawCircle(c.danger, 3.2f * u, Offset(cx + 8 * u, cy - 8 * u))
        drawCircle(Color.White.copy(alpha = 0.35f), 3.2f * u, Offset(cx + 8 * u, cy - 8 * u), style = Stroke(0.4f * u))
        // stream status card floating
        val card = Rect(cx + 14 * u, cy + 6 * u, cx + 40 * u, cy + 16 * u)
        drawRoundRect(if (c.isDark) Color(0xFF1A2146) else Color.White, card.topLeft, card.size, CornerRadius(2 * u))
        drawRoundRect(Color.White.copy(alpha = 0.15f), card.topLeft, card.size, CornerRadius(2 * u), style = Stroke(0.25f * u))
        drawCircle(c.success, 1.6f * u, Offset(card.left + 3.4f * u, card.center.y))
        drawRoundRect(c.textSecondary.copy(alpha = 0.6f), Offset(card.left + 7 * u, card.top + 2.5f * u), Size(14 * u, 1.4f * u), CornerRadius(u))
        drawRoundRect(c.textTertiary.copy(alpha = 0.5f), Offset(card.left + 7 * u, card.top + 5.6f * u), Size(9 * u, 1.2f * u), CornerRadius(u))
        val card2 = Rect(cx - 40 * u, cy - 14 * u, cx - 15 * u, cy - 5 * u)
        drawRoundRect(if (c.isDark) Color(0xFF1A2146) else Color.White, card2.topLeft, card2.size, CornerRadius(2 * u))
        drawRoundRect(Color.White.copy(alpha = 0.15f), card2.topLeft, card2.size, CornerRadius(2 * u), style = Stroke(0.25f * u))
        drawCircle(c.accentEnd, 1.6f * u, Offset(card2.left + 3.4f * u, card2.center.y))
        drawRoundRect(c.textSecondary.copy(alpha = 0.6f), Offset(card2.left + 7 * u, card2.top + 2.2f * u), Size(13 * u, 1.4f * u), CornerRadius(u))
        drawRoundRect(c.textTertiary.copy(alpha = 0.5f), Offset(card2.left + 7 * u, card2.top + 5.2f * u), Size(8 * u, 1.2f * u), CornerRadius(u))
    }
}
