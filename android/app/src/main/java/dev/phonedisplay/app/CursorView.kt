package dev.phonedisplay.app

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.util.AttributeSet
import android.util.Log
import android.view.View
import kotlin.math.max
import kotlin.math.min

/**
 * The Mac pointer, drawn by us — and scaled up.
 *
 * The host streams only the pointer's position (tiny cursor packets), so this
 * view can render the cursor at any size and at full frame rate, completely
 * independently of the video stream. [cursorScale] is the multiplier over the
 * Mac's native 12x19 px cursor (fixed at 3x).
 */
class CursorView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    companion object {
        const val DEFAULT_SCALE = 3.0f
        private const val BASE_W = 12.4f   // cursor units (1x = Mac pixels)
        private const val BASE_H = 19.0f
    }

    /** Arrow size multiplier. 1x = Mac-native size on a 1:1 stream. */
    val cursorScale: Float = DEFAULT_SCALE

    // classic macOS arrow, hotspot at (0,0), in 1x units
    private val arrow = Path().apply {
        moveTo(0f, 0f)
        lineTo(0f, 16.9f)
        lineTo(4.15f, 13.05f)
        lineTo(6.7f, 18.75f)
        lineTo(9.5f, 17.35f)
        lineTo(7.05f, 12.0f)
        lineTo(12.2f, 12.0f)
        close()
    }

    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = Color.WHITE
    }
    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = Color.BLACK
        strokeWidth = 1.4f              // in cursor units — scales with the arrow
        strokeJoin = Paint.Join.ROUND
    }

    @Volatile private var cursorVisible = false
    @Volatile private var cx = 0f
    @Volatile private var cy = 0f
    @Volatile private var videoW = 0
    @Volatile private var videoH = 0
    @Volatile private var loggedDraw = false

    // pen mode: a small, unobtrusive hint so it is obvious why fingers do
    // nothing — a white dot with a dark ring near the top-right edge.
    @Volatile private var penMode = false
    private val penDotPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = Color.argb(140, 255, 255, 255)
    }
    private val penDotRingPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = Color.argb(140, 0, 0, 0)
        strokeWidth = 2.5f
    }

    fun setPenMode(on: Boolean) {
        if (penMode == on) return
        penMode = on
        postInvalidateOnAnimation()      // whole view; mode changes are rare
    }

    fun setVideoSize(w: Int, h: Int) {
        videoW = w
        videoH = h
    }

    /** Called from the network thread; cheap and invalidation-throttled. */
    fun updateFromStream(visible: Boolean, x: Float, y: Float) {
        val old = dirtyRect()
        cursorVisible = visible
        cx = x
        cy = y
        invalidateUnion(old)
    }

    private fun invalidateUnion(old: IntArray) {
        val new = dirtyRect()
        postInvalidateOnAnimation(
            min(old[0], new[0]), min(old[1], new[1]),
            max(old[2], new[2]), max(old[3], new[3]),
        )
    }

    /** Pixel rect the cursor currently occupies (with margin), for partial redraws. */
    private fun dirtyRect(): IntArray {
        val sx = if (videoW > 0) width.toFloat() / videoW else 1f
        val sy = if (videoH > 0) height.toFloat() / videoH else 1f
        val k = min(sx, sy) * cursorScale
        val margin = max(4f, 3f * k)    // stroke + antialiasing
        val left = cx * sx - margin
        val top = cy * sy - margin
        return intArrayOf(
            left.toInt(),
            top.toInt(),
            (left + BASE_W * k + 2 * margin).toInt(),
            (top + BASE_H * k + 2 * margin).toInt(),
        )
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (penMode) {
            val r = 9f
            val dotX = width - 44f
            val dotY = 44f
            canvas.drawCircle(dotX, dotY, r, penDotPaint)
            canvas.drawCircle(dotX, dotY, r, penDotRingPaint)
        }
        if (!cursorVisible) return
        if (!loggedDraw) {
            loggedDraw = true
            Log.i("PhoneDisplay", "cursor first draw at ($cx,$cy)  view=${width}x$height  " +
                    "video=${videoW}x$videoH  scale=$cursorScale")
        }
        val sx = if (videoW > 0) width.toFloat() / videoW else 1f
        val sy = if (videoH > 0) height.toFloat() / videoH else 1f
        val k = min(sx, sy) * cursorScale
        canvas.save()
        canvas.translate(cx * sx, cy * sy)
        canvas.scale(k, k)
        canvas.drawPath(arrow, fillPaint)
        canvas.drawPath(arrow, strokePaint)
        canvas.restore()
    }
}
