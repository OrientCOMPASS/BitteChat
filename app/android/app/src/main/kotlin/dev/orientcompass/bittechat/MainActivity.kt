package dev.orientcompass.bittechat

import android.content.Intent
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
