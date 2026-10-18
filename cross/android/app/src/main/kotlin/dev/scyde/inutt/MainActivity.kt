package dev.scyde.inutt

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity is required for the biometric prompt.
class MainActivity : FlutterFragmentActivity() {
    private var pending: MethodChannel.Result? = null

    // The sync file lives wherever you pick it (Google Drive, another cloud app, or the phone),
    // through Android's document picker; access to it is kept across restarts.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "inutt/sync").setMethodCallHandler { call, result ->
            when (call.method) {
                "create", "open" -> {
                    pending?.error("busy", "Another pick is open", null)
                    pending = result
                    val intent = Intent(if (call.method == "create") Intent.ACTION_CREATE_DOCUMENT else Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = if (call.method == "create") "application/octet-stream" else "*/*"
                        if (call.method == "create") putExtra(Intent.EXTRA_TITLE, "iNUTT-sync.inutt")
                    }
                    startActivityForResult(intent, PICK)
                }
                "read" -> Thread {
                    val bytes = try {
                        contentResolver.openInputStream(Uri.parse(call.argument<String>("uri")))?.use { it.readBytes() }
                    } catch (e: Exception) { null }
                    runOnUiThread { result.success(bytes) }
                }.start()
                "write" -> Thread {
                    val err = try {
                        contentResolver.openOutputStream(Uri.parse(call.argument<String>("uri")), "wt")?.use {
                            it.write(call.argument<ByteArray>("data")!!)
                        }
                        null
                    } catch (e: Exception) { e.message ?: "write failed" }
                    runOnUiThread { if (err == null) result.success(true) else result.error("write", err, null) }
                }.start()
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK) return
        val r = pending ?: return
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            r.success(null)
            return
        }
        try {
            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        } catch (_: Exception) {}
        var name = "iNUTT-sync.inutt"
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) name = it.getString(0) ?: name
        }
        r.success(mapOf("uri" to uri.toString(), "name" to name))
    }

    companion object { private const val PICK = 7041 }
}
