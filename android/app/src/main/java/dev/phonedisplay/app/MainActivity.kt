package dev.phonedisplay.app

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.InputDevice
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import java.io.BufferedInputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.ByteBuffer

/**
 * PhoneDisplay — turns this phone into a second monitor for the Mac.
 *
 * Speaks the PD01 protocol (see project README):
 *   → "PD01\n"            handshake request
 *   ← "PD01 w h fps h264\n"
 *   ← [u32 len][u8 flags][Annex-B H.264 access unit] ...video
 *   ← [u32 len][u8 flags 0x02][u8 visible|i32be x|i32be y] ...cursor
 *   → [u32 len][u8 flags 0x04][u8 kind|u8 buttons|i32be x|i32be y] ...input
 *
 * S-Pen mode: when the pen leaves the silo, the stylus drives the Mac cursor
 * (hover = move, tip tap = click, side button + tap = right-click) and finger
 * touches are ignored, so the pen rests on the glass without clicking things.
 * Put the pen back and finger control returns immediately.
 *
 * USB mode: run `adb reverse tcp:8420 tcp:8420` on the Mac, then connect
 * to 127.0.0.1:8420 here. Wi-Fi mode: use the Mac's LAN IP.
 */
class MainActivity : Activity(), SurfaceHolder.Callback {

    companion object {
        private const val TAG = "PhoneDisplay"
        private const val DEFAULT_ADDR = "127.0.0.1:8420"
        private const val CONNECT_TIMEOUT_MS = 5_000
        // The host creates the virtual display on demand, so the greeting only
        // arrives after the first keyframe exists — allow for SCK startup.
        private const val GREETING_TIMEOUT_MS = 15_000
        // Read tick while streaming. Deliberately short: the stream is
        // change-driven, so when the Mac goes still we wake up every tick and
        // flush the decoder instead of waiting for a next packet that may
        // never come (the phone would keep showing the previous picture).
        private const val FRAME_TIMEOUT_MS = 250
        private const val MID_PACKET_STALL_MS = 10_000
        private const val MAX_FRAME_BYTES = 8 shl 20
        private const val PEN_FALLBACK_IDLE_MS = 20_000L
    }

    private lateinit var surfaceView: SurfaceView
    private lateinit var cursorView: CursorView
    private lateinit var overlay: View
    private lateinit var hostField: EditText
    private lateinit var statusView: TextView
    private lateinit var fpsPill: LinearLayout
    private lateinit var fps60View: TextView
    private lateinit var fps90View: TextView
    private lateinit var fpsHotspot: View

    /** Phone-chosen stream frame rate (capture cap on the host). */
    private var chosenFps = 90

    @Volatile private var surface: Surface? = null
    @Volatile private var running = false
    @Volatile private var socket: Socket? = null
    private var rxCursors = 0L
    private var worker: Thread? = null

    // Every startStreaming() bumps this; threads from an older session see a
    // mismatch and bow out, so two stream loops can never fight over the socket.
    private val sessionLock = Any()
    private var sessionId = 0

    // ------------------------------------------------------- S-Pen mode

    @Volatile private var penMode = false        // stylus drives the Mac?
    @Volatile private var sockOut: java.io.OutputStream? = null
    @Volatile private var streamW = 0
    @Volatile private var streamH = 0

    private val outLock = Any()
    private val inputQueue = java.util.concurrent.ArrayBlockingQueue<ByteArray>(512)
    private var heldButton = -1                  // -1 none, 0 left, 1 right
    private var penButtonHeld = false            // side button, from last event
    private var lastPenX = 0
    private var lastPenY = 0
    private var lastPenMoveAt = 0L
    private var penHoverCount = 0L
    private var lastLoggedButton = false
    private var hudGesture = false               // tip gesture belongs to the fps HUD

    private val mainHandler = Handler(Looper.getMainLooper())

    /** Fallback: if the Samsung detach broadcast never arrives, pen mode from
     *  stylus activity alone turns itself off after this much stylus silence. */
    private val penIdleOff = Runnable { setPenMode(false, "stylus idle") }

    private val penReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val inserted = intent.getBooleanExtra("penInsert", true)
            Log.i(TAG, "S-Pen broadcast: ${intent.action} penInsert=$inserted")
            setPenMode(!inserted, "broadcast")
        }
    }

    override fun onStart() {
        super.onStart()
        val filter = IntentFilter("com.samsung.pen.INSERT")
        try {
            if (Build.VERSION.SDK_INT >= 33)
                registerReceiver(penReceiver, filter, Context.RECEIVER_EXPORTED)
            else
                @Suppress("UnspecifiedRegisterReceiverFlag")
                registerReceiver(penReceiver, filter)
        } catch (e: Exception) {
            Log.w(TAG, "could not register pen receiver", e)
        }
    }

    override fun onStop() {
        try { unregisterReceiver(penReceiver) } catch (_: Exception) {}
        super.onStop()
    }

    private fun setPenMode(on: Boolean, source: String) {
        mainHandler.removeCallbacks(penIdleOff)
        if (on) {
            if (!penMode) Log.i(TAG, "pen mode ON ($source)")
            penMode = true
            // Last-resort auto-off for every source: a missed Samsung
            // "pen inserted" broadcast must never leave fingers dead forever.
            mainHandler.postDelayed(penIdleOff, PEN_FALLBACK_IDLE_MS)
            cursorView.setPenMode(true)
        } else {
            if (!penMode) return
            penMode = false
            hudGesture = false
            if (heldButton >= 0) {                     // never leave a click stuck
                sendInput(2, heldButton, lastPenX, lastPenY)
                heldButton = -1
            }
            Log.i(TAG, "pen mode OFF ($source)")
            cursorView.setPenMode(false)
        }
    }

    /** A stylus event proves the pen is out of the silo. */
    private fun noteStylusActivity() {
        if (!penMode) {
            setPenMode(true, "stylus")
        } else {
            mainHandler.removeCallbacks(penIdleOff)
            mainHandler.postDelayed(penIdleOff, PEN_FALLBACK_IDLE_MS)
        }
    }

    // -------------------------------------------------- stylus event routing

    /** Runs before any view sees the event; consumes it when pen mode is on. */
    override fun dispatchTouchEvent(ev: MotionEvent): Boolean =
        handleStylusEvent(ev) || super.dispatchTouchEvent(ev)

    override fun dispatchGenericMotionEvent(ev: MotionEvent): Boolean =
        handleStylusEvent(ev) || super.dispatchGenericMotionEvent(ev)

    private fun handleStylusEvent(ev: MotionEvent): Boolean {
        val action = ev.actionMasked
        val hover = action == MotionEvent.ACTION_HOVER_ENTER ||
                action == MotionEvent.ACTION_HOVER_MOVE ||
                action == MotionEvent.ACTION_HOVER_EXIT
        val idx = if (hover) 0 else ev.actionIndex
        val tool = if (idx in 0 until ev.pointerCount) ev.getToolType(idx) else -1
        val fromPen = ev.isFromSource(InputDevice.SOURCE_STYLUS) ||
                tool == MotionEvent.TOOL_TYPE_STYLUS || tool == MotionEvent.TOOL_TYPE_ERASER

        // Fingers: ignored (fully) while the pen controls the Mac.
        val active = penMode && sockOut != null
        if (!fromPen) return active

        noteStylusActivity()          // every stylus event resets the idle timer

        // The fps HUD must stay reachable with the pen: a *tip* gesture that
        // starts inside the hotspot/pill goes to the views, not the Mac.
        // Hover still moves the pointer, so only tip events are diverted.
        val tip = action == MotionEvent.ACTION_DOWN || action == MotionEvent.ACTION_MOVE ||
                action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL
        if (action == MotionEvent.ACTION_DOWN) hudGesture = inFpsUi(ev.rawX, ev.rawY)
        if (hudGesture && tip) {
            if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL)
                hudGesture = false
            return false
        }

        if (action == MotionEvent.ACTION_HOVER_EXIT) {
            // Pen left the hover range: nothing can still be pressed. Release
            // explicitly so a missed ACTION_UP can never stick the Mac button.
            if (heldButton >= 0) {
                sendInput(2, heldButton, lastPenX, lastPenY)
                heldButton = -1
            }
            return true
        }

        val sx = if (streamW > 0 && cursorView.width > 0)
            streamW.toFloat() / cursorView.width else 1f
        val sy = if (streamH > 0 && cursorView.height > 0)
            streamH.toFloat() / cursorView.height else 1f
        val x = (ev.x * sx).toInt()
        val y = (ev.y * sy).toInt()
        val btn = (ev.buttonState and
                (MotionEvent.BUTTON_STYLUS_PRIMARY or MotionEvent.BUTTON_STYLUS_SECONDARY)) != 0

        // Local echo: draw our big cursor exactly under the pen tip right away,
        // instead of waiting for the event to travel to the Mac and back.
        // Incoming cursor packets keep re-confirming the position.
        cursorView.updateFromStream(true, x.toFloat(), y.toFloat())

        when (action) {
            MotionEvent.ACTION_HOVER_ENTER, MotionEvent.ACTION_HOVER_MOVE -> {
                if (heldButton >= 0) {
                    // Tip is in the air, so no button can still be down — a
                    // missed ACTION_UP would leave the Mac dragging forever.
                    sendInput(2, heldButton, lastPenX, lastPenY)
                    heldButton = -1
                }
                penButtonHeld = btn
                lastPenX = x
                lastPenY = y
                sendPenMove(x, y)                         // hover only moves
            }
            MotionEvent.ACTION_DOWN -> {
                heldButton = if (btn || penButtonHeld) 1 else 0
                penButtonHeld = btn
                lastPenX = x
                lastPenY = y
                sendInput(1, heldButton, x, y)
            }
            MotionEvent.ACTION_MOVE -> {
                lastPenX = x
                lastPenY = y
                sendPenMove(x, y)                         // drag if button held
            }
            MotionEvent.ACTION_UP -> {
                sendInput(2, if (heldButton >= 0) heldButton else 0, x, y)
                heldButton = -1
                penButtonHeld = btn
            }
            MotionEvent.ACTION_CANCEL -> {
                if (heldButton >= 0) {
                    sendInput(2, heldButton, lastPenX, lastPenY)
                    heldButton = -1
                }
            }
        }

        // Telemetry for real-pen testing: every non-hover event, hover moves
        // sampled 1/100, and immediately whenever the side button changes.
        if (action == MotionEvent.ACTION_HOVER_MOVE) penHoverCount++
        if (action != MotionEvent.ACTION_HOVER_MOVE ||
            penHoverCount % 100 == 0L || btn != lastLoggedButton
        ) {
            lastLoggedButton = btn
            Log.i(TAG, "stylus: action=$action tool=$tool buttons=${ev.buttonState} " +
                    "pressure=${ev.pressure} -> ($x,$y)")
        }
        return true
    }

    /** Move events are capped at ~250/s — plenty for a pointer, cheap on USB. */
    private fun sendPenMove(x: Int, y: Int) {
        val now = SystemClock.uptimeMillis()
        if (now - lastPenMoveAt < 4) return
        lastPenMoveAt = now
        sendInput(0, if (heldButton >= 0) heldButton else 0, x, y)
    }

    /** Is this screen position over the tap-to-reveal hotspot or the open pill? */
    private fun inFpsUi(rawX: Float, rawY: Float): Boolean {
        val loc = IntArray(2)
        if (fpsPill.visibility == View.VISIBLE) {
            fpsPill.getLocationOnScreen(loc)
            if (rawX >= loc[0] && rawX < loc[0] + fpsPill.width &&
                    rawY >= loc[1] && rawY < loc[1] + fpsPill.height) return true
        }
        fpsHotspot.getLocationOnScreen(loc)
        return rawX >= loc[0] && rawX < loc[0] + fpsHotspot.width &&
                rawY >= loc[1] && rawY < loc[1] + fpsHotspot.height
    }

    /**
     * Input packet → host: u8 kind (0 move, 1 down, 2 up) | u8 buttons
     * (bit0 = right/side-button) | int32be x | int32be y.
     *
     * Touch events arrive on the UI thread; network I/O is forbidden there
     * (NetworkOnMainThreadException), so packets go through a small queue
     * drained by a daemon sender thread. The queue never blocks the UI.
     */
    private fun sendInput(kind: Int, buttons: Int, x: Int, y: Int) {
        val rec = byteArrayOf(
            0, 0, 0, 10, 0x04,                            // length | input flag
            kind.toByte(), buttons.toByte(),
            (x ushr 24).toByte(), ((x ushr 16) and 0xFF).toByte(),
            ((x ushr 8) and 0xFF).toByte(), (x and 0xFF).toByte(),
            (y ushr 24).toByte(), ((y ushr 16) and 0xFF).toByte(),
            ((y ushr 8) and 0xFF).toByte(), (y and 0xFF).toByte(),
        )
        if (!inputQueue.offer(rec)) {                     // full: keep the newest
            inputQueue.poll()
            inputQueue.offer(rec)
        }
    }

    // ---------------------------------------------------- frame-rate selector

    private val hidePill = Runnable { fadePillOut() }

    /** Shows the fps pill; autoHide makes it fade out again after 4 s. */
    private fun revealPill(autoHide: Boolean) {
        mainHandler.removeCallbacks(hidePill)
        fpsPill.animate().cancel()
        fpsPill.visibility = View.VISIBLE
        fpsPill.alpha = 1f
        if (autoHide) mainHandler.postDelayed(hidePill, 4_000)
    }

    private fun fadePillOut() {
        if (overlay.visibility == View.VISIBLE) return   // settings screen: keep
        fpsPill.animate().cancel()
        fpsPill.animate().alpha(0f).setDuration(250)
            .withEndAction { if (overlay.visibility != View.VISIBLE) fpsPill.visibility = View.GONE }
    }

    /** Applies the choice: persists it and live-applies on the running stream. */
    private fun setFpsChoice(fps: Int) {
        if (fps != chosenFps) {
            chosenFps = fps
            getSharedPreferences("pd", MODE_PRIVATE).edit().putInt("fps", fps).apply()
            sendControl(1, fps)
        }
        updateFpsUi()
        mainHandler.removeCallbacks(hidePill)
        mainHandler.postDelayed(hidePill, 1_500)         // linger briefly, then hide
    }

    private fun updateFpsUi() {
        fps60View.setBackgroundColor(if (chosenFps == 60) 0xCC2E7DD1.toInt() else 0x00000000)
        fps90View.setBackgroundColor(if (chosenFps == 90) 0xCC2E7DD1.toInt() else 0x00000000)
    }

    /**
     * Control packet → host: u32 len | u8 flags (0x08) | u8 cmd | u8 arg.
     * cmd 1 = capture frame-rate cap. Goes through the same queue as input
     * (never touch the socket on the UI thread).
     */
    private fun sendControl(cmd: Int, arg: Int) {
        val rec = byteArrayOf(0, 0, 0, 2, 0x08, cmd.toByte(), arg.toByte())
        if (!inputQueue.offer(rec)) {
            inputQueue.poll()
            inputQueue.offer(rec)
        }
    }

    /** Drains queued input packets to the current session socket. */
    private fun inputSenderLoop() {
        while (true) {
            val rec = try {
                inputQueue.take()
            } catch (_: InterruptedException) {
                break
            }
            val out = sockOut ?: continue                 // not connected: drop
            synchronized(outLock) {
                try {
                    out.write(rec)
                } catch (_: IOException) { /* session loop will reconnect */ }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or View.SYSTEM_UI_FLAG_FULLSCREEN
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
        )

        if (Build.VERSION.SDK_INT >= 28) {
            // Let the video extend into the camera-cutout band. Without this,
            // Android insets the window by the full cutout depth (128px here)
            // in landscape, leaving a black strip and squeezing the picture.
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode = if (Build.VERSION.SDK_INT >= 30)
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                else
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }

        surfaceView = findViewById(R.id.surface)
        cursorView = findViewById(R.id.cursor)
        overlay = findViewById(R.id.overlay)
        hostField = findViewById(R.id.host)
        statusView = findViewById(R.id.status)
        fpsPill = findViewById(R.id.fpsPill)
        fps60View = findViewById(R.id.fps60)
        fps90View = findViewById(R.id.fps90)
        fpsHotspot = findViewById(R.id.fpsHotspot)
        val connectButton: Button = findViewById(R.id.connect)

        val prefs = getSharedPreferences("pd", MODE_PRIVATE)
        hostField.setText(prefs.getString("host", DEFAULT_ADDR) ?: DEFAULT_ADDR)
        chosenFps = if (prefs.getInt("fps", 90) == 60) 60 else 90
        updateFpsUi()
        fps60View.setOnClickListener { setFpsChoice(60) }
        fps90View.setOnClickListener { setFpsChoice(90) }
        // The rate pill is hidden while streaming; tapping the top-left corner
        // brings it back (it fades out again by itself).
        fpsHotspot.setOnClickListener { revealPill(autoHide = true) }
        revealPill(autoHide = false)     // visible on the connect screen

        surfaceView.holder.addCallback(this)

        Thread({ inputSenderLoop() }, "pd-input").apply {
            isDaemon = true
            start()
        }

        connectButton.setOnClickListener {
            val addr = hostField.text.toString().ifBlank { DEFAULT_ADDR }
            prefs.edit().putString("host", addr).apply()
            startStreaming(addr)
        }
    }

    override fun onDestroy() {
        running = false
        try { socket?.close() } catch (_: Exception) {}
        worker?.interrupt()
        super.onDestroy()
    }

    // ------------------------------------------------------ surface callbacks

    override fun surfaceCreated(holder: SurfaceHolder) {
        surface = holder.surface
        setStatus(getString(R.string.ready))
        // Auto-connect on launch / when the surface comes back, so returning
        // to the app never leaves it stuck on a stale screen.
        if (!running) startStreaming(hostField.text.toString().ifBlank { DEFAULT_ADDR })
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        surface = null
        running = false
        cursorView.updateFromStream(false, 0f, 0f)
        try { socket?.close() } catch (_: Exception) {}   // wake the worker now
    }

    // ------------------------------------------------------ stream control

    private fun setStatus(text: String) {
        runOnUiThread { statusView.text = text }
    }

    private fun startStreaming(addr: String) {
        // Invalidate any previous worker first, even if we cannot start a new
        // one: an old loop must never keep the old session alive.
        val id = synchronized(sessionLock) { ++sessionId }
        running = false
        try { socket?.close() } catch (_: Exception) {}   // wake a blocked old worker
        worker?.interrupt()
        if (surface == null) {
            setStatus(getString(R.string.no_surface))
            return
        }
        running = true
        worker = Thread({ streamLoop(addr, id) }, "pd-stream").also { it.start() }
    }

    private fun streamLoop(addr: String, id: Int) {
        while (running && id == sessionId) {
            try {
                runSession(addr, id)
                setStatus(getString(R.string.stream_ended))
            } catch (e: Exception) {
                if (!running || id != sessionId) break
                Log.w(TAG, "session error", e)
                setStatus("retrying in 3 s — ${e.message}")
            }
            runOnUiThread {
                overlay.visibility = View.VISIBLE
                revealPill(autoHide = false)     // connect screen: pill available
            }
            cursorView.updateFromStream(false, 0f, 0f)
            if (id == sessionId) sockOut = null
            if (!running || id != sessionId) break
            try {
                Thread.sleep(3_000)
            } catch (_: InterruptedException) {
                break
            }
        }
    }

    private fun runSession(addr: String, id: Int) {
        val host = addr.substringBefore(":").ifBlank { "127.0.0.1" }
        val port = addr.substringAfter(":", "8420").toIntOrNull() ?: 8420

        setStatus("connecting to $host:$port …")
        Socket().use { sock ->
            socket = sock
            sock.tcpNoDelay = true
            sock.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)

            val input = BufferedInputStream(sock.getInputStream(), 1 shl 20)
            val out = sock.getOutputStream()

            sock.soTimeout = GREETING_TIMEOUT_MS
            // The greeting must hit the wire *before* the input sender may use
            // this socket, or a pen packet could precede "PD01\n" and desync
            // the host's input stream.
            synchronized(outLock) {
                out.write("PD01\n".toByteArray(Charsets.US_ASCII))
                out.flush()
            }
            sockOut = out

            val hello = readLine(input) ?: throw IOException("no greeting from host")
            val parts = hello.trim().split(" ")
            if (parts.size < 5 || parts[0] != "PD01") throw IOException("bad greeting: $hello")
            val width = parts[1].toInt()
            val height = parts[2].toInt()
            val fps = parts[3].toInt()
            streamW = width
            streamH = height
            Log.i(TAG, "stream $width x $height @ $fps")
            setStatus("streaming ${width}x$height @ $fps")
            cursorView.setVideoSize(width, height)
            sendControl(1, chosenFps)     // apply the app's frame-rate choice

            sock.soTimeout = FRAME_TIMEOUT_MS
            decodeLoop(input, width, height, fps)
        }
        if (id == sessionId) {
            socket = null
            sockOut = null
        }
    }

    // ------------------------------------------------------ decoding

    private fun decodeLoop(input: InputStream, width: Int, height: Int, fps: Int) {
        var decoder: MediaCodec? = null
        var frameIndex = 0L
        var dropped = 0L
        var firstRendered = false
        var au = ByteArray(1 shl 20)
        var lastAu: ByteArray? = null
        var lastLen = 0
        var lastPts = 0L
        var nudges = 0
        var statsAt = android.os.SystemClock.elapsedRealtime()
        var statsFrames = 0L

        try {
            while (running) {
                val hdr = readFrameHeader(input) ?: break
                if (hdr.isEmpty()) {
                    // Idle tick: nothing arrived within the read timeout. Let
                    // the decoder finish the frame we last fed — the stream is
                    // change-driven, so on a still screen no next frame will
                    // arrive to flush it out of the codec.
                    if (firstRendered && decoder != null) {
                        var released = drainDecoder(decoder, 25_000)
                        if (released == 0 && nudges < 3 && lastAu != null) {
                            // Qualcomm decoders keep the newest picture queued
                            // until one more input arrives. Re-feed the last
                            // access unit (a duplicate picture) so the final
                            // frame of a burst is actually shown.
                            if (feedDecoder(decoder, lastAu, lastLen, lastPts + 1_000)) {
                                nudges++
                                released = drainDecoder(decoder, 60_000)
                            }
                        }
                        if (released > 0) Log.i(TAG, "idle drain: released $released frame(s)")
                    }
                    continue
                }
                val length = ((hdr[0].toInt() and 0xFF) shl 24) or
                        ((hdr[1].toInt() and 0xFF) shl 16) or
                        ((hdr[2].toInt() and 0xFF) shl 8) or
                        (hdr[3].toInt() and 0xFF)
                val flags = hdr[4].toInt() and 0xFF
                val keyframe = (flags and 0x01) != 0
                if (length <= 0 || length > MAX_FRAME_BYTES)
                    throw IOException("bad frame length: $length")
                if (au.size < length) au = ByteArray(length)
                if (!readExactInto(input, au, length)) break

                if (flags and 0x02 != 0) {
                    // cursor position packet (not video): hand to the overlay
                    handleCursorPacket(au, length)
                    continue
                }

                if (decoder == null) {
                    // wait for the first keyframe — it carries SPS/PPS
                    if (!keyframe) continue
                    decoder = createDecoder(au, length, width, height) ?: continue
                    runOnUiThread {
                        overlay.visibility = View.GONE
                        fadePillOut()        // keep the video clean: no pill
                    }
                    Log.i(TAG, "decoder started")
                }

                val ptsUs = frameIndex * 1_000_000L / fps
                if (!feedDecoder(decoder, au, length, ptsUs)) dropped++
                frameIndex++
                nudges = 0
                if (lastAu == null || lastAu.size < length) lastAu = ByteArray(length)
                au.copyInto(lastAu, 0, 0, length)
                lastLen = length
                lastPts = ptsUs
                if (firstRendered) {
                    drainDecoder(decoder)
                } else {
                    // The decoder may only flush its first picture when the
                    // next frame arrives, and the output shows up a few ms
                    // later. A zero-timeout drain would miss both — and on a
                    // static screen there is no later frame to trigger another
                    // drain, so the phone would stay black.
                    val t0 = android.os.SystemClock.elapsedRealtime()
                    val deadline = t0 + 400
                    var released = 0
                    while (released == 0 &&
                            android.os.SystemClock.elapsedRealtime() < deadline) {
                        released = drainDecoder(decoder, 100_000)
                    }
                    if (released > 0) {
                        firstRendered = true
                        Log.i(TAG, "first output after " +
                                "${android.os.SystemClock.elapsedRealtime() - t0} ms " +
                                "(frame #$frameIndex, $length bytes)")
                    }
                }

                // phone-side video stats: one line every 2 s
                val now = android.os.SystemClock.elapsedRealtime()
                if (now - statsAt >= 2000) {
                    val got = frameIndex - statsFrames
                    Log.i(TAG, "video: %.1f fps, %d frames, %d dropped"
                            .format(got * 1000.0 / (now - statsAt), frameIndex, dropped))
                    statsAt = now
                    statsFrames = frameIndex
                }
            }
        } finally {
            try { decoder?.stop() } catch (_: Exception) {}
            try { decoder?.release() } catch (_: Exception) {}
            Log.i(TAG, "session done: $frameIndex frames, $dropped dropped")
            if (dropped > 0) Log.w(TAG, "dropped frames this session: $dropped")
        }
    }

    /** Parses a 0x02 cursor packet: u8 visible | int32be x | int32be y. */
    private fun handleCursorPacket(au: ByteArray, length: Int) {
        if (length < 9) return
        fun be32(o: Int): Int = ((au[o].toInt() and 0xFF) shl 24) or
                ((au[o + 1].toInt() and 0xFF) shl 16) or
                ((au[o + 2].toInt() and 0xFF) shl 8) or
                (au[o + 3].toInt() and 0xFF)
        val visible = au[0].toInt() != 0
        val x = be32(1).toFloat()
        val y = be32(5).toFloat()
        rxCursors++
        if (rxCursors <= 3 || rxCursors % 300 == 0L) {
            Log.i(TAG, "cursor packet #$rxCursors: visible=$visible x=$x y=$y")
        }
        cursorView.updateFromStream(visible, x, y)
    }

    private fun createDecoder(au: ByteArray, length: Int, width: Int, height: Int): MediaCodec? {
        val surface = this.surface ?: return null

        val sps = findNal(au, length, 7) ?: return null
        val pps = findNal(au, length, 8) ?: return null

        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
        format.setByteBuffer("csd-0", ByteBuffer.wrap(sps))
        format.setByteBuffer("csd-1", ByteBuffer.wrap(pps))

        val decoder = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        decoder.configure(format, surface, null, 0)
        decoder.start()
        return decoder
    }

    private fun feedDecoder(decoder: MediaCodec, au: ByteArray, length: Int, ptsUs: Long): Boolean {
        val idx = decoder.dequeueInputBuffer(10_000)
        if (idx < 0) return false
        val buf = decoder.getInputBuffer(idx) ?: return false
        buf.clear()
        buf.put(au, 0, length)
        decoder.queueInputBuffer(idx, 0, length, ptsUs, 0)
        return true
    }

    /** Releases decoded frames; returns how many were released. */
    private fun drainDecoder(decoder: MediaCodec, waitUs: Long = 0): Int {
        val info = MediaCodec.BufferInfo()
        var released = 0
        while (true) {
            when (val idx = decoder.dequeueOutputBuffer(info, waitUs)) {
                in 0..Int.MAX_VALUE -> {
                    decoder.releaseOutputBuffer(idx, true)
                    released++
                }
                MediaCodec.INFO_TRY_AGAIN_LATER -> return released
                else -> { /* INFO_OUTPUT_FORMAT_CHANGED / BUFFERS_CHANGED */ }
            }
        }
    }

    // ------------------------------------------------------ helpers

    /** Returns the NAL unit (including its start code) if present, else null. */
    private fun findNal(au: ByteArray, length: Int, type: Int): ByteArray? {
        var i = 0
        while (i + 4 <= length) {
            if (!isStartCode(au, i)) {
                i++
                continue
            }
            var j = i + 4
            while (j + 4 <= length && !isStartCode(au, j)) j++
            val end = if (j + 4 <= length) j else length
            if (i + 4 < end && (au[i + 4].toInt() and 0x1F) == type)
                return au.copyOfRange(i, end)
            i = if (end > i) end else i + 1
        }
        return null
    }

    private fun isStartCode(b: ByteArray, at: Int): Boolean =
        b[at] == 0.toByte() && b[at + 1] == 0.toByte() &&
                b[at + 2] == 0.toByte() && b[at + 3] == 1.toByte()

    private fun readLine(input: InputStream): String? {
        val sb = StringBuilder()
        while (true) {
            val b = input.read()
            if (b < 0) return if (sb.isEmpty()) null else sb.toString()
            if (b == '\n'.code) return sb.toString()
            if (b != '\r'.code) sb.append(b.toChar())
            if (sb.length > 512) return sb.toString()
        }
    }

    private fun readExact(input: InputStream, n: Int): ByteArray? {
        val out = ByteArray(n)
        return if (readExactInto(input, out, n)) out else null
    }

    /**
     * Reads a 5-byte frame header. Idle desktops legitimately send nothing for
     * minutes, so a read timeout before any header bytes arrive returns an
     * empty array: the caller flushes the decoder and tries again. That keeps
     * the *last* frame of a burst from sitting undisplayed in the codec when
     * the screen goes still. A timeout mid-header or mid-payload beyond the
     * stall budget means the link really died, and the session is restarted.
     */
    private fun readFrameHeader(input: InputStream): ByteArray? {
        val out = ByteArray(5)
        var off = 0
        var lastProgress = android.os.SystemClock.elapsedRealtime()
        while (off < 5) {
            val r = try {
                input.read(out, off, 5 - off)
            } catch (_: SocketTimeoutException) {
                if (!running) return null
                if (off == 0) return ByteArray(0)            // idle tick
                if (android.os.SystemClock.elapsedRealtime() - lastProgress > MID_PACKET_STALL_MS)
                    throw IOException("stream stalled mid-header")
                continue
            }
            if (r < 0) {
                if (off == 0) return null                    // clean close
                throw IOException("connection cut mid-header")
            }
            off += r
            lastProgress = android.os.SystemClock.elapsedRealtime()
        }
        return out
    }

    private fun readExactInto(input: InputStream, out: ByteArray, n: Int): Boolean {
        var off = 0
        var lastProgress = android.os.SystemClock.elapsedRealtime()
        while (off < n) {
            val r = try {
                input.read(out, off, n - off)
            } catch (_: SocketTimeoutException) {
                if (android.os.SystemClock.elapsedRealtime() - lastProgress > MID_PACKET_STALL_MS)
                    throw IOException("stream stalled mid-payload")
                continue
            }
            if (r < 0) return false
            off += r
            lastProgress = android.os.SystemClock.elapsedRealtime()
        }
        return true
    }
}
