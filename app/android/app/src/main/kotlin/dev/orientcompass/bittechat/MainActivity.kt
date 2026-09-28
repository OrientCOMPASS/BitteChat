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
    private var pendingMagnet: String? = null
    private var launchConsumed = false

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
