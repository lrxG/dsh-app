package com.lanbuddy.lan_buddy

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Native side of two thin bridges:
 *  - `lanbuddy/notify`: the "DSH 事件" channel and its permission.
 *  - `lanbuddy/files`: SAF document picking (copies into cache, returns a path).
 *
 * Both are dependency-free so the Gradle setup stays on the stock Flutter
 * toolchain.
 */
class MainActivity : FlutterActivity() {
    private val channelId = "dsh_events"
    private val notificationPermissionRequest = 7301
    private val filePickRequest = 7302
    private var nextNotificationId = 1
    private var pendingPick: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lanbuddy/notify")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "init" -> {
                        ensureChannel()
                        requestPostNotifications()
                        result.success(true)
                    }
                    "show" -> {
                        ensureChannel()
                        val title = call.argument<String>("title") ?: "DSH"
                        val body = call.argument<String>("body") ?: ""
                        show(title, body)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lanbuddy/files")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pick" -> {
                        if (pendingPick != null) {
                            result.error("busy", "a file picker is already open", null)
                            return@setMethodCallHandler
                        }
                        pendingPick = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                        }
                        startActivityForResult(intent, filePickRequest)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != filePickRequest) return
        val pending = pendingPick ?: return
        pendingPick = null
        val uri: Uri? = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            pending.success(null)
            return
        }
        try {
            val name = queryDisplayName(uri) ?: "file"
            val safe = name.replace(Regex("[^A-Za-z0-9._-]"), "_")
            // Only one attachment is staged at a time; drop older temp copies so
            // the picker cache cannot grow without bound.
            cacheDir.listFiles { file -> file.name.startsWith("picked-") }
                ?.forEach { it.delete() }
            val target = File(cacheDir, "picked-${System.currentTimeMillis()}-$safe")
            contentResolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            } ?: throw IllegalStateException("cannot open the picked document")
            pending.success(
                mapOf(
                    "path" to target.absolutePath,
                    "name" to name,
                    "size" to target.length(),
                ),
            )
        } catch (error: Exception) {
            pending.error("read-failed", error.message, null)
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) return cursor.getString(0)
            }
        return null
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(channelId) != null) return
        val channel = NotificationChannel(
            channelId,
            "DSH 事件",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "审批请求与会话完成提醒"
        }
        manager.createNotificationChannel(channel)
    }

    private fun requestPostNotifications() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), notificationPermissionRequest)
    }

    private fun show(title: String, body: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val notification = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .build()
        NotificationManagerCompat.from(this).notify(nextNotificationId++, notification)
    }
}
