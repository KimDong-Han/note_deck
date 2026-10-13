package dev.smithkim.notedeck

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import androidx.core.content.ContextCompat

/** Self-drawn fader (no SeekBar hacks). Horizontal by default, vertical with app:vertical="true". */
class FaderView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {

    interface Listener {
        fun onProgressChanged(progress: Int, fromUser: Boolean)
        fun onStartTracking()
        fun onStopTracking(progress: Int)
    }

    var max = 127
    var progress = 0
        set(v) { field = v.coerceIn(0, max); invalidate(); listener?.onProgressChanged(field, false) }
    var vertical = false
    var listener: Listener? = null

    private val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = ContextCompat.getColor(context, R.color.surface_active) }
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = ContextCompat.getColor(context, R.color.accent) }
    private val knobPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = ContextCompat.getColor(context, R.color.text) }
    private val trackWidth = dp(8f)
    private val knobR = dp(14f)
    private val rect = RectF()

    init {
        context.theme.obtainStyledAttributes(attrs, R.styleable.FaderView, 0, 0).apply {
            try { vertical = getBoolean(R.styleable.FaderView_vertical, false) } finally { recycle() }
        }
    }

    private fun dp(v: Float) = v * resources.displayMetrics.density

    /** Usable travel for the knob centre. */
    private fun travel(): Pair<Float, Float> = if (vertical)
        Pair(paddingTop + knobR, height - paddingBottom - knobR)
    else
        Pair(paddingLeft + knobR, width - paddingRight - knobR)

    private fun knobPos(): Float {
        val (a, b) = travel()
        val f = progress.toFloat() / max
        return if (vertical) b - (b - a) * f else a + (b - a) * f
    }

    override fun onDraw(c: Canvas) {
        val (a, b) = travel()
        val pos = knobPos()
        val r = trackWidth / 2
        if (vertical) {
            val cx = width / 2f
            rect.set(cx - r, a, cx + r, b); c.drawRoundRect(rect, r, r, trackPaint)
            rect.set(cx - r, pos, cx + r, b); c.drawRoundRect(rect, r, r, fillPaint)
            c.drawCircle(cx, pos, knobR, knobPaint)
        } else {
            val cy = height / 2f
            rect.set(a, cy - r, b, cy + r); c.drawRoundRect(rect, r, r, trackPaint)
            rect.set(a, cy - r, pos, cy + r); c.drawRoundRect(rect, r, r, fillPaint)
            c.drawCircle(pos, cy, knobR, knobPaint)
        }
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        if (!isEnabled) return false
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> { parent?.requestDisallowInterceptTouchEvent(true); listener?.onStartTracking(); track(e) }
            MotionEvent.ACTION_MOVE -> track(e)
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> { track(e); listener?.onStopTracking(progress) }
        }
        return true
    }

    private fun track(e: MotionEvent) {
        val (a, b) = travel()
        val f = if (vertical) (b - e.y) / (b - a) else (e.x - a) / (b - a)
        val p = (f.coerceIn(0f, 1f) * max).toInt()
        if (p != progress) {
            progress = p
            listener?.onProgressChanged(p, true)
        }
    }
}
