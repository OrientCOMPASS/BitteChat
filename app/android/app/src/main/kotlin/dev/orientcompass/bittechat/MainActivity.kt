package dev.orientcompass.bittechat

import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Forwards magnet: intents (browser / QR scanners / other apps) to Dart so
 * the chat tab can offer "join this group".
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var mediaChannel: MethodChannel? = null
    private var pendingMagnet: String? = null
    private var launchConsumed = false
    private var focusRequest: android.media.AudioFocusRequest? = null

    // Whether a fresh AUDIOFOCUS_GAIN request should be honoured. Dart flips
    // this to false after the user pauses (or the system revokes focus) so a
    // video that keeps emitting `playing=true` cannot yank focus back and
    // re-interrupt the user's own music; it is set true again when playback
    // really stops. See core/media_focus.dart.
    @Volatile
    private var acceptAudioFocusGain = true

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bittechat/intent")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "takePendingMagnet" -> {
                    val m = pendingMagnet
                        ?: if (!launchConsumed) {
                            intent?.dataString?.takeIf { it.startsWith("magnet:") }
                        } else {
                            null
                        }
                    pendingMagnet = null
                    launchConsumed = true
                    result.success(m)
                }
                else -> result.notImplemented()
            }
        }
        channel = ch
        pendingMagnet?.let { m ->
            try {
                ch.invokeMethod("magnet", m)
            } catch (e: Exception) {
                android.util.Log.w("bittechat", "magnet forward failed: $e")
            }
        }

        // Audio focus: a playing video/voice message must INTERRUPT whatever
        // other app is making noise (music player, browser, ...) instead of
        // mixing on top of it, and must itself pause when focus is revoked.
        // minSdk is 28, so AudioFocusRequest is safe. Focus changes are
        // forwarded to Dart (core/media_focus.dart) so the active player pauses.
        val media = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, "bittechat/media")
        mediaChannel = media
        media.setMethodCallHandler { call, result ->
                val am = getSystemService(android.content.Context.AUDIO_SERVICE)
                        as? android.media.AudioManager
                if (am == null) {
                    result.success(false)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "requestAudioFocus" -> {
                        if (!acceptAudioFocusGain) {
                            // the user (or the system) asked us to be quiet;
                            // do not steal focus back until playback stops
                            result.success(false)
                        } else {
                            val req = focusRequest ?: android.media.AudioFocusRequest
                                .Builder(android.media.AudioManager.AUDIOFOCUS_GAIN)
                                .setAudioAttributes(
                                    android.media.AudioAttributes.Builder()
                                        .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                                        .setContentType(
                                            android.media.AudioAttributes.CONTENT_TYPE_MUSIC)
                                        .build())
                                .setOnAudioFocusChangeListener { change ->
                                    // GAIN(>=0) re-arms us; any LOSS pauses Dart
                                    acceptAudioFocusGain = change >= 0
                                    runOnUiThread {
                                        try {
                                            mediaChannel?.invokeMethod(
                                                "audioFocusChange", change)
                                        } catch (e: Exception) {
                                            android.util.Log.w(
                                                "bittechat", "focus forward failed: $e")
                                        }
                                    }
                                }
                                .build()
                                .also { focusRequest = it }
                            val r = am.requestAudioFocus(req)
                            result.success(
                                r == android.media.AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
                        }
                    }
                    "abandonAudioFocus" -> {
                        focusRequest?.let { am.abandonAudioFocusRequest(it) }
                        focusRequest = null
                        acceptAudioFocusGain = true
                        result.success(true)
                    }
                    "setAcceptAudioFocusGain" -> {
                        acceptAudioFocusGain = call.argument<Boolean>("accept") ?: true
                        result.success(true)
                    }
                    // Screen brightness for the player's left-edge vertical
                    // drag. -1 (BRIGHTNESS_OVERRIDE_NONE) means "follow system",
                    // in which case fall back to the system setting value.
                    "getBrightness" -> {
                        val lp = window.attributes
                        val v = if (lp.screenBrightness >= 0f) {
                            lp.screenBrightness
                        } else {
                            android.provider.Settings.System.getInt(
                                contentResolver,
                                android.provider.Settings.System.SCREEN_BRIGHTNESS,
                                128
                            ).toFloat() / 255f
                        }
                        result.success(v.coerceIn(0.02f, 1f))
                    }
                    "setBrightness" -> {
                        val v = (call.argument<Double>("value") ?: 0.5)
                            .toFloat().coerceIn(0.02f, 1f)
                        val lp = window.attributes
                        lp.screenBrightness = v
                        window.attributes = lp
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bittechat/files")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "exportToDownloads" -> {
                        val path = call.argument<String>("path")
                        val name = call.argument<String>("name")
                            ?: "bittechat-log.txt"
                        val file = path?.let { java.io.File(it) }
                        if (file == null || !file.exists()) {
                            result.error("no_file", "log bundle missing", null)
                        } else {
                            try {
                                val bytes = file.readBytes()
                                if (android.os.Build.VERSION.SDK_INT >= 29) {
                                    val values = android.content.ContentValues().apply {
                                        put(android.provider.MediaStore.Downloads.DISPLAY_NAME, name)
                                        put(android.provider.MediaStore.Downloads.MIME_TYPE, "text/plain")
                                        put(android.provider.MediaStore.Downloads.RELATIVE_PATH,
                                            android.os.Environment.DIRECTORY_DOWNLOADS + "/BitteChat")
                                        put(android.provider.MediaStore.Downloads.IS_PENDING, 1)
                                    }
                                    val uri = contentResolver.insert(
                                        android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                                        values) ?: throw IllegalStateException("insert failed")
                                    contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                                        ?: throw IllegalStateException("no stream")
                                    values.clear()
                                    values.put(android.provider.MediaStore.Downloads.IS_PENDING, 0)
                                    contentResolver.update(uri, values, null, null)
                                    result.success("Download/BitteChat/$name")
                                } else {
                                    @Suppress("DEPRECATION")
                                    val dir = android.os.Environment
                                        .getExternalStoragePublicDirectory(
                                            android.os.Environment.DIRECTORY_DOWNLOADS)
                                    if (!dir.exists()) dir.mkdirs()
                                    val out = java.io.File(dir, name)
                                    out.writeBytes(bytes)
                                    result.success(out.absolutePath)
                                }
                            } catch (e: Exception) {
                                result.error("export_failed", e.message, null)
                            }
                        }
                    }
                    "openWith" -> {
                        val path = call.argument<String>("path")
                        val mime = call.argument<String>("mime") ?: "*/*"
                        val file = path?.let { java.io.File(it) }
                        if (file == null || !file.exists()) {
                            result.success(false)
                        } else {
                            try {
                                val uri = FileProvider.getUriForFile(
                                    this, "$packageName.fileprovider", file)
                                val view = Intent(Intent.ACTION_VIEW)
                                    .setDataAndType(uri, mime)
                                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                startActivity(Intent.createChooser(view, "打开方式"))
                                result.success(true)
                            } catch (e: Exception) {
                                result.success(false)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        focusRequest?.let { req ->
            (getSystemService(android.content.Context.AUDIO_SERVICE)
                    as? android.media.AudioManager)?.abandonAudioFocusRequest(req)
        }
        focusRequest = null
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val data = intent.dataString
        if (data != null && data.startsWith("magnet:")) {
            pendingMagnet = data
            // Fast background->foreground switches can deliver onNewIntent
            // while the Flutter engine is detached/destroyed; invokeMethod
            // then crashes natively with no Dart-side trace. Guard it — the
            // pending value is picked up on the next takePendingMagnet.
            try {
                if (!isFinishing && !isDestroyed) {
                    channel?.invokeMethod("magnet", data)
                }
            } catch (e: Exception) {
                android.util.Log.w("bittechat", "magnet forward failed: $e")
            }
        }
    }
}
