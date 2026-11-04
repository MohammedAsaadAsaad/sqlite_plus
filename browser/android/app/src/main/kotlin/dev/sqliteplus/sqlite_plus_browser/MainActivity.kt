package dev.sqliteplus.sqlite_plus_browser

import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val io = Executors.newSingleThreadExecutor()
    private var channel: MethodChannel? = null
    private var pending: Map<String, Any?>? = null
    private var launchTaken = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.sqliteplus.browser/files",
        )
        channel = messenger
        messenger.setMethodCallHandler { call, result ->
            when (call.method) {
                "documents" -> result.success(filesDir.absolutePath)
                "takeLaunch" -> {
                    launchTaken = true
                    val payload = pending
                    pending = null
                    result.success(payload)
                }
                "read" -> {
                    val location = call.argument<String>("location")
                    if (location.isNullOrEmpty()) {
                        result.success(null)
                    } else {
                        io.execute {
                            val bytes = readUri(Uri.parse(location))
                            runOnUiThread { result.success(bytes) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        capture(intent, deliver = false)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        capture(intent, deliver = true)
    }

    private fun capture(intent: Intent?, deliver: Boolean) {
        if (intent?.action != Intent.ACTION_VIEW) return
        val uri = intent.data ?: return
        if (uri.scheme == "content") {
            try {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            } catch (_: SecurityException) {
            }
        }
        io.execute {
            val bytes = readUri(uri) ?: return@execute
            val payload = mapOf(
                "name" to displayName(uri),
                "location" to uri.toString(),
                "bytes" to bytes,
            )
            runOnUiThread {
                if (deliver || launchTaken) {
                    pending = null
                    channel?.invokeMethod("opened", payload)
                } else {
                    pending = payload
                }
            }
        }
    }

    private fun readUri(uri: Uri): ByteArray? {
        return try {
            if (uri.scheme == "file") {
                val path = uri.path ?: return null
                File(path).readBytes()
            } else {
                contentResolver.openInputStream(uri)?.use { it.readBytes() }
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun displayName(uri: Uri): String {
        if (uri.scheme == "content") {
            try {
                contentResolver.query(
                    uri,
                    arrayOf(OpenableColumns.DISPLAY_NAME),
                    null,
                    null,
                    null,
                )?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (index >= 0) {
                            val name = cursor.getString(index)
                            if (!name.isNullOrEmpty()) return name
                        }
                    }
                }
            } catch (_: Exception) {
            }
        }
        val leaf = uri.lastPathSegment
        if (!leaf.isNullOrEmpty()) return leaf.substringAfterLast('/')
        return "database.sqlite"
    }
}
