package dev.smithkim.notedeck

import android.content.Context
import android.graphics.drawable.AnimatedImageDrawable
import android.graphics.drawable.Drawable
import android.view.Gravity
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.ContextCompat

/** One deck button: icon (image / glyph) on top, label below. Hosts animated GIFs in a real ImageView. */
class DeckTileView(context: Context) : LinearLayout(context) {
    private val image = ImageView(context)
    private val glyph = TextView(context)
    private val label = TextView(context)
    private fun dp(v: Int) = (v * resources.displayMetrics.density + 0.5f).toInt()

    init {
        orientation = VERTICAL
        gravity = Gravity.CENTER
        isClickable = true; isFocusable = true
        setPadding(dp(8), dp(10), dp(8), dp(10))
        setActive(false)
        val iconSize = dp(44)
        image.scaleType = ImageView.ScaleType.FIT_CENTER
        addView(image, LayoutParams(iconSize, iconSize))
        glyph.textSize = 34f; glyph.gravity = Gravity.CENTER; glyph.includeFontPadding = false
        glyph.setTextColor(ContextCompat.getColor(context, R.color.text))
        addView(glyph, LayoutParams(LayoutParams.WRAP_CONTENT, iconSize))
        label.textSize = 16f; label.gravity = Gravity.CENTER; label.maxLines = 1
        label.setTextColor(ContextCompat.getColor(context, R.color.text))
        addView(label, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).also { it.topMargin = dp(8) })
    }

    fun setLabel(text: String) { label.text = text; label.visibility = if (text.isBlank()) GONE else VISIBLE }

    fun setIcon(d: Drawable?, tint: Int?) {
        glyph.visibility = GONE; image.visibility = VISIBLE
        image.setImageDrawable(d)
        image.imageTintList = tint?.let { ContextCompat.getColorStateList(context, it) }
        (d as? AnimatedImageDrawable)?.let { it.repeatCount = AnimatedImageDrawable.REPEAT_INFINITE; it.start() }
    }

    fun setGlyph(text: String) {
        image.setImageDrawable(null); image.visibility = GONE
        glyph.visibility = VISIBLE; glyph.text = text
        glyph.textSize = if (text.length <= 2) 34f else 20f
    }

    fun setActive(active: Boolean) {
        background = ContextCompat.getDrawable(context, if (active) R.drawable.bg_deck_button_active else R.drawable.bg_deck_button)
    }
}
