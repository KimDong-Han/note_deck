package dev.smithkim.notedeck

import android.content.Context
import android.media.midi.MidiDevice
import android.media.midi.MidiDeviceInfo
import android.media.midi.MidiInputPort
import android.media.midi.MidiManager
import android.media.midi.MidiOutputPort
import android.media.midi.MidiReceiver
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Talks to the Mac over the phone's USB MIDI peripheral port.
 * Phone -> Mac: note on/off, control change.  Mac -> phone: feedback (same message types).
 */
class MidiLink(context: Context, private val listener: Listener) {

    interface Listener {
        fun onMidiState(connected: Boolean, deviceName: String?)
        fun onMidiMessage(status: Int, data1: Int, data2: Int)
        fun onSysEx(data: ByteArray)
    }

    companion object { private const val TAG = "MidiLink" }

    private val handler = Handler(Looper.getMainLooper())
    private val manager = context.getSystemService(Context.MIDI_SERVICE) as MidiManager
    private var device: MidiDevice? = null
    private var inPort: MidiInputPort? = null     // we send into this
    private var outPort: MidiOutputPort? = null   // feedback comes out of this
    val isConnected: Boolean get() = inPort != null

    private val deviceCallback = object : MidiManager.DeviceCallback() {
        override fun onDeviceAdded(info: MidiDeviceInfo) { Log.i(TAG, "added ${name(info)}"); if (device == null) openPeripheral() }
        override fun onDeviceRemoved(info: MidiDeviceInfo) {
            Log.i(TAG, "removed ${name(info)}")
            if (device?.info?.id == info.id) { close(); listener.onMidiState(false, null) }
        }
    }

    private val receiver = object : MidiReceiver() {
        private var running = 0
        private var d1 = -1
        private var sysex: java.io.ByteArrayOutputStream? = null
        override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
            if (sysex == null && count <= 8) Log.d(TAG, "recv " + (offset until offset + count).joinToString(" ") { "%02X".format(msg[it].toInt() and 0xFF) })
            for (i in offset until offset + count) {
                val b = msg[i].toInt() and 0xFF
                if (b >= 0xF8) continue                    // realtime
                if (b == 0xF0) { sysex = java.io.ByteArrayOutputStream(); continue }
                sysex?.let { buf ->
                    if (b == 0xF7) { val d = buf.toByteArray(); sysex = null; Log.i(TAG, "sysex ${d.size} bytes"); handler.post { listener.onSysEx(d) } }
                    else if (b < 0x80) buf.write(b)
                    else sysex = null                      // interrupted by a status byte
                    return@let
                }
                if (sysex != null) continue
                if (b >= 0x80) { running = b; d1 = -1; continue }
                val kind = running and 0xF0
                if (kind == 0x80 || kind == 0x90 || kind == 0xB0) {
                    if (d1 < 0) d1 = b else { val st = running; val a = d1; d1 = -1; handler.post { listener.onMidiMessage(st, a, b) } }
                }
            }
        }
    }

    fun start() {
        manager.registerDeviceCallback(deviceCallback, handler)
        openPeripheral()
    }

    fun stop() {
        manager.unregisterDeviceCallback(deviceCallback)
        close()
    }

    private fun name(info: MidiDeviceInfo): String =
        info.properties.getString(MidiDeviceInfo.PROPERTY_NAME) ?: "midi#${info.id}"

    /** The phone's own USB peripheral port shows up as a USB device named "Android USB Peripheral Port". */
    private fun findPeripheral(): MidiDeviceInfo? {
        @Suppress("DEPRECATION")
        val all = manager.devices.toList()
        all.forEach { Log.i(TAG, "device: ${name(it)} type=${it.type} in=${it.inputPortCount} out=${it.outputPortCount}") }
        return all.firstOrNull { it.type == MidiDeviceInfo.TYPE_USB && name(it).contains("peripheral", true) }
            ?: all.firstOrNull { it.type == MidiDeviceInfo.TYPE_USB && it.inputPortCount > 0 }
    }

    fun openPeripheral() {
        if (device != null) return
        val info = findPeripheral()
        if (info == null) { listener.onMidiState(false, null); return }
        manager.openDevice(info, { dev ->
            if (dev == null) { Log.w(TAG, "openDevice null"); listener.onMidiState(false, null); return@openDevice }
            device = dev
            inPort = dev.openInputPort(0)
            outPort = dev.openOutputPort(0)?.also { it.connect(receiver) }
            Log.i(TAG, "opened ${name(info)} in=${inPort != null} out=${outPort != null}")
            listener.onMidiState(inPort != null, name(info))
        }, handler)
    }

    private fun close() {
        try { outPort?.disconnect(receiver); outPort?.close(); inPort?.close(); device?.close() } catch (_: Exception) {}
        outPort = null; inPort = null; device = null
    }

    private fun send(status: Int, d1: Int, d2: Int) {
        val port = inPort ?: run { Log.w(TAG, "send: no port"); return }
        Log.d(TAG, "send %02X %02X %02X".format(status, d1, d2))
        try { port.send(byteArrayOf(status.toByte(), (d1 and 0x7F).toByte(), (d2 and 0x7F).toByte()), 0, 3) }
        catch (e: Exception) { Log.w(TAG, "send failed: $e") }
    }

    fun noteOn(note: Int, velocity: Int = 127, channel: Int = 1) = send(0x90 or ((channel - 1) and 0x0F), note, velocity)
    fun noteOff(note: Int, channel: Int = 1) = send(0x80 or ((channel - 1) and 0x0F), note, 0)
    fun cc(num: Int, value: Int, channel: Int = 1) = send(0xB0 or ((channel - 1) and 0x0F), num, value)
}
