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
        pendingMagnet?.let { ch.invokeMethod("magnet", it) }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bittechat/files")
            .setMethodCallHandler { call, result ->
                when (call.method) {
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
            channel?.invokeMethod("magnet", data)
        }
    }
}
