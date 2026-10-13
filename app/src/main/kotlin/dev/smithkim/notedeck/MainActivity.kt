package dev.smithkim.notedeck

import android.content.res.Configuration
import android.graphics.ImageDecoder
import android.graphics.drawable.Drawable
import android.util.Base64
import android.os.Bundle
import android.os.SystemClock
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.GridLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import android.util.Log

class MainActivity : AppCompatActivity(), MidiLink.Listener {

    companion object { const val SYNC_REQUEST_CC = 119; const val IMAGE_REQUEST_CC = 118; const val IMAGE_ACK_CC = 117; const val PHONE_SCREEN_CC = 116 }

    private lateinit var status: View
    private lateinit var grid: GridLayout
    private lateinit var sliderRow: View
    private lateinit var slider: FaderView
    private lateinit var sliderValue: TextView

    private lateinit var midi: MidiLink
    private lateinit var config: DeckConfig
    private val buttonsByNote = HashMap<Int, DeckTileView>()
    private var userDragging = false
    private val imageChunks = HashMap<Int, Array<ByteArray?>>()
    private var blackout: View? = null
    private var lastCcSent = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        enterFullscreen()
        val root = findViewById<View>(android.R.id.content)
        ViewCompat.setOnApplyWindowInsetsListener(root) { v, insets ->
            val cut = insets.getInsets(WindowInsetsCompat.Type.displayCutout())
            v.setPadding(cut.left, cut.top, cut.right, cut.bottom)
            insets
        }

        status = findViewById(R.id.status)
        grid = findViewById(R.id.grid)
        sliderRow = findViewById(R.id.sliderRow)
        slider = findViewById(R.id.slider)
        sliderValue = findViewById(R.id.sliderValue)

        config = try {
            DeckConfig.load(this)
        } catch (e: Exception) {
            Toast.makeText(this, "deck.json 오류: ${e.message}", Toast.LENGTH_LONG).show()
            DeckConfig(2, 3, emptyList(), null)
        }
        buildGrid()
        buildSlider()

        midi = MidiLink(this, this)
        midi.start()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) enterFullscreen()
    }

    /** Hide status + navigation bars; swipe from an edge shows them temporarily. */
    private fun enterFullscreen() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.attributes = window.attributes.apply {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    /** "Screen off": black overlay + brightness 0 (AMOLED pixels are really off). Tap or a wake from the Mac restores it. */
    private fun screenOff() {
        if (blackout != null) return
        val root = findViewById<android.view.ViewGroup>(android.R.id.content)
        blackout = View(this).apply {
            setBackgroundColor(0xFF000000.toInt())
            isClickable = true
            setOnClickListener { screenOn() }
        }
        root.addView(blackout, android.view.ViewGroup.LayoutParams.MATCH_PARENT, android.view.ViewGroup.LayoutParams.MATCH_PARENT)
        window.attributes = window.attributes.apply { screenBrightness = 0f }
        Log.i("MainActivity", "screen off")
    }

    private fun screenOn() {
        val b = blackout ?: return
        (b.parent as? android.view.ViewGroup)?.removeView(b)
        blackout = null
        window.attributes = window.attributes.apply { screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE }
        enterFullscreen()
        Log.i("MainActivity", "screen on")
    }

    override fun onDestroy() {
        midi.stop()
        super.onDestroy()
    }

    // ---- MidiLink.Listener ----

    override fun onMidiState(connected: Boolean, deviceName: String?) {
        status.setBackgroundResource(if (connected) R.drawable.dot_green else R.drawable.dot_red)
        status.contentDescription = getString(if (connected) R.string.status_connected else R.string.status_waiting)
        if (connected) midi.cc(SYNC_REQUEST_CC, 0)   // ask the Mac for current state (active output, mute, volume)
        if (!connected) { buttonsByNote.values.forEach { setActive(it, false) }; sliderValue.text = "--" }
    }

    /** Layout / icon pushed from the Mac: 7D 'N' 'D' <cmd> [note] <base64>. */
    override fun onSysEx(data: ByteArray) {
        if (data.size < 5 || data[0] != 0x7D.toByte() || data[1] != 'N'.code.toByte() || data[2] != 'D'.code.toByte()) return
        try {
            when (data[3].toInt()) {
                1 -> {
                    val json = String(Base64.decode(data, 4, data.size - 4, Base64.DEFAULT), Charsets.UTF_8)
                    config = DeckConfig.parse(json)
                    DeckConfig.save(this, json)
                    Log.i("MainActivity", "layout received: ${config.buttons.size} buttons")
                    buildGrid(); buildSlider()    // the Mac sends feedback right after a layout push
                    // ask only for images we don't have (or whose hash changed)
                    config.buttons.filter { it.hasImage && !DeckConfig.hasIcon(this, it) }.forEach { requestImage(it, 0) }
                }
                2 -> {   // image chunk: <note> <idxHi> <idxLo> <totalHi> <totalLo> base64…  (ACK each one so the Mac paces itself)
                    val note = data[4].toInt()
                    val idx = (data[5].toInt() shl 7) or data[6].toInt()
                    val total = (data[7].toInt() shl 7) or data[8].toInt()
                    var parts = imageChunks[note]
                    if (parts == null || parts.size != total) { parts = arrayOfNulls(total); imageChunks[note] = parts }
                    parts[idx] = data.copyOfRange(9, data.size)
                    midi.cc(IMAGE_ACK_CC, idx and 0x7F)
                    val done = parts.count { it != null }
                    buttonsByNote[note]?.setLabel(if (done < total) "↓ ${done * 100 / total}%" else "↓ 100%")
                    if (done == total) {
                        imageChunks.remove(note)
                        val b64 = parts.fold(ByteArray(0)) { acc, p -> acc + p!! }
                        val bytes = Base64.decode(b64, Base64.DEFAULT)
                        DeckConfig.iconFile(this, note).writeBytes(bytes)
                        Log.i("MainActivity", "icon received for note $note (${bytes.size} bytes, $total chunks)")
                        config.buttons.firstOrNull { it.note == note }?.let { b ->
                            b.imageHash?.let { DeckConfig.iconHashFile(this, note).writeText(it) }
                            buttonsByNote[note]?.let { t -> t.setLabel(b.label); applyIcon(t, b) }
                        }
                    }
                }
            }
        } catch (e: Exception) { Log.w("MainActivity", "sysex error: $e") }
    }

    /** Ask the Mac for a button image; retry a few times if no chunk shows up (request can race the Mac's state). */
    private fun requestImage(b: DeckButton, attempt: Int) {
        if (!midi.isConnected || DeckConfig.hasIcon(this, b) || attempt > 3) return
        if (attempt > 0 && imageChunks[b.note]?.any { it != null } == true) return   // transfer in progress
        Log.i("MainActivity", "requesting image for note ${b.note} (attempt $attempt)")
        buttonsByNote[b.note]?.setLabel("↓ …")
        midi.cc(IMAGE_REQUEST_CC, b.note)
        slider.postDelayed({ requestImage(b, attempt + 1) }, 5000)
    }

    override fun onMidiMessage(status: Int, data1: Int, data2: Int) {
        Log.d("MainActivity", "midi %02X %d %d".format(status, data1, data2))
        when (status and 0xF0) {
            0x90 -> buttonsByNote[data1]?.let { setActive(it, data2 > 0) }
            0x80 -> buttonsByNote[data1]?.let { setActive(it, false) }
            0xB0 -> if (data1 == PHONE_SCREEN_CC) {
                if (data2 == 0) screenOff() else screenOn()
            } else if (config.slider?.cc == data1 && !userDragging) {
                slider.progress = data2
                sliderValue.text = "${data2 * 100 / 127}%"
            }
        }
    }

    // ---- UI ----

    private fun buildGrid() {
        grid.removeAllViews()
        buttonsByNote.clear()
        val land = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        grid.columnCount = if (land) config.columnsLand else config.columns
        val gap = dp(12)
        config.buttons.forEach { b ->
            val btn = DeckTileView(this).apply {
                setLabel(b.label)
                // note on at finger down, note off at release — lets the Mac side do hold actions later
                setOnTouchListener { v, ev ->
                    when (ev.actionMasked) {
                        MotionEvent.ACTION_DOWN -> press(b)
                        MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> midi.noteOff(b.note)
                    }
                    false
                }
                setOnClickListener { }
            }
            applyIcon(btn, b)
            buttonsByNote[b.note] = btn
            val lp = GridLayout.LayoutParams(
                GridLayout.spec(GridLayout.UNDEFINED, 1f),
                GridLayout.spec(GridLayout.UNDEFINED, 1f)
            ).apply {
                width = 0
                height = 0                          // rows share the available height
                setMargins(gap / 2, gap / 2, gap / 2, gap / 2)
                setGravity(Gravity.FILL)
            }
            grid.addView(btn, lp)
        }
    }

    private fun press(b: DeckButton) {
        Log.d("MainActivity", "press ${b.label} connected=${midi.isConnected}")
        if (!midi.isConnected) { Toast.makeText(this, R.string.not_connected, Toast.LENGTH_SHORT).show(); return }
        midi.noteOn(b.note)
    }

    private fun buildSlider() {
        val s = config.slider
        if (s == null) { sliderRow.visibility = View.GONE; return }
        slider.listener = object : FaderView.Listener {
            override fun onProgressChanged(progress: Int, fromUser: Boolean) {
                if (!fromUser) return
                sliderValue.text = "${progress * 100 / 127}%"
                val now = SystemClock.uptimeMillis()
                if (now - lastCcSent >= 25) { lastCcSent = now; midi.cc(s.cc, progress) }
            }
            override fun onStartTracking() { userDragging = true }
            override fun onStopTracking(progress: Int) {
                userDragging = false
                midi.cc(s.cc, progress)   // always deliver the final value
            }
        }
    }

    private fun setActive(tile: DeckTileView, active: Boolean) = tile.setActive(active)

    private val brandIcons = setOf("claude", "anthropic", "openai")

    /** Icon priority: pushed image file > glyph > built-in drawable ic_<icon> > key. */
    private fun applyIcon(tile: DeckTileView, b: DeckButton) {
        val file = DeckConfig.iconFile(this, b.note)
        val drawable: Drawable? = if (DeckConfig.hasIcon(this, b)) {
            try { ImageDecoder.decodeDrawable(ImageDecoder.createSource(file)) }
            catch (e: Exception) { Log.w("MainActivity", "icon decode failed for ${b.note}: $e"); null }
        } else null
        when {
            drawable != null -> tile.setIcon(drawable, null)
            b.glyph != null -> tile.setGlyph(b.glyph)
            else -> {
                val id = resources.getIdentifier("ic_" + b.icon.lowercase(), "drawable", packageName)
                tile.setIcon(ContextCompat.getDrawable(this, if (id != 0) id else R.drawable.ic_key),
                    if (b.icon.lowercase() in brandIcons) null else R.color.text)
            }
        }
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density + 0.5f).toInt()
}
