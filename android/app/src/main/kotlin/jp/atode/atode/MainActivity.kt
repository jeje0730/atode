package jp.atode.atode

import io.flutter.embedding.android.FlutterActivity
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val pending = mutableListOf<Map<String, String>>()
    private var channel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // A recreated activity must not replay a share already consumed by Dart.
        if (savedInstanceState == null) capture(intent)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "jp.atode/share")
        channel!!.setMethodCallHandler { call, result ->
            if (call.method == "takePending") {
                val batch = pending.toList()
                pending.clear()
                result.success(batch)
            } else result.notImplemented()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        capture(intent)
        channel?.invokeMethod("available", null)
    }

    private fun capture(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND || intent.type != "text/plain") return
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString().orEmpty()
        if (text.isNotBlank()) pending.add(mapOf(
            "text" to text.take(32000),
            "subject" to intent.getStringExtra(Intent.EXTRA_SUBJECT).orEmpty().take(1000)
        ))
        intent.removeExtra(Intent.EXTRA_TEXT)
    }
}
