package dev.smithkim.notedeck

import android.content.Context
import org.json.JSONObject
import java.io.File

/**
 * Button layout. Loaded from <filesDir>/deck.json if present (user-editable), otherwise assets/deck.json.
 *
 * {
 *   "columns": 2,            // portrait
 *   "columns_land": 3,       // landscape (optional)
 *   "buttons": [ { "label": "...", "icon": "laptop|headphones|mute|key|claude|...", "note": 60, "glyph": "🎧"?, "has_image": true? } ],
 *   "slider":  { "label": "Volume", "cc": 7 }          // optional
 * }
 * The Mac app's config.json maps note:<n> / cc:<n> to actions.
 */
data class DeckButton(val label: String, val icon: String, val note: Int, val glyph: String? = null, val hasImage: Boolean = false, val imageHash: String? = null)
data class DeckSlider(val label: String, val cc: Int)

data class DeckConfig(val columns: Int, val columnsLand: Int, val buttons: List<DeckButton>, val slider: DeckSlider?) {
    companion object {
        const val FILE_NAME = "deck.json"

        fun save(context: Context, json: String) = File(context.filesDir, FILE_NAME).writeText(json)
        fun iconFile(context: Context, note: Int) = File(context.filesDir, "icon_$note.png")
        fun iconHashFile(context: Context, note: Int) = File(context.filesDir, "icon_$note.hash")
        /** True when the cached image matches the hash the Mac announced. */
        fun hasIcon(context: Context, b: DeckButton): Boolean =
            b.hasImage && iconFile(context, b.note).exists() && (b.imageHash == null || iconHashFile(context, b.note).takeIf { it.exists() }?.readText() == b.imageHash)

        fun load(context: Context): DeckConfig {
            val local = File(context.filesDir, FILE_NAME)
            val text = if (local.exists()) local.readText()
            else context.assets.open(FILE_NAME).bufferedReader().use { it.readText() }
            return parse(text)
        }

        fun parse(text: String): DeckConfig {
            val root = JSONObject(text)
            val columns = root.optInt("columns", 2).coerceIn(1, 6)
            val columnsLand = root.optInt("columns_land", 3).coerceIn(1, 8)
            val arr = root.getJSONArray("buttons")
            val buttons = (0 until arr.length()).map { i ->
                val o = arr.getJSONObject(i)
                DeckButton(o.optString("label", "?"), o.optString("icon", "key"), o.getInt("note"),
                    o.optString("glyph", "").ifEmpty { null }, o.optBoolean("has_image", false), o.optString("image_hash", "").ifEmpty { null })
            }
            val slider = root.optJSONObject("slider")?.let { DeckSlider(it.optString("label", "Volume"), it.optInt("cc", 7)) }
            return DeckConfig(columns, columnsLand, buttons, slider)
        }
    }
}
