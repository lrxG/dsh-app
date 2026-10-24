package com.lanbuddy.lan_buddy

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Native side of three thin bridges:
 *  - `lanbuddy/notify`: the "DSH 事件" channel, its permission, and the
 *    notification-tap hand-off (a tap carries the session id back to Dart).
 *  - `lanbuddy/files`: SAF document picking (copies into cache, returns a path).
 *  - `lanbuddy/power`: battery-optimization state and the system settings that
 *    let a paired phone keep a socket alive in the background.
 *
 * No foreground service: nothing is posted until a task actually finishes.
 * All are dependency-free so the Gradle setup stays on the stock toolchain.
 */
class MainActivity : FlutterActivity() {
    private val channelId = "dsh_events"
    private val notificationPermissionRequest = 7301
    private val filePickRequest = 7302
    private var nextNotificationId = 1
    private var pendingPick: MethodChannel.Result? = null

    /// Notification tap that arrived before Dart was listening.
    private var pendingSession: String? = null
    private var notifyChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        pendingSession = sessionFrom(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lanbuddy/notify")
            .also { notifyChannel = it }
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
                        show(title, body, call.argument<String>("sessionId"))
                        result.success(true)
                    }
                    "takePending" -> {
                        val id = pendingSession
                        pendingSession = null
                        result.success(id)
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lanbuddy/power")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> {
                        val power = getSystemService(PowerManager::class.java)
                        result.success(
                            mapOf("ignoring" to power.isIgnoringBatteryOptimizations(packageName)),
                        )
                    }
                    "request" -> result.success(openIgnoreBatteryOptimizations())
                    "appSettings" -> {
                        try {
                            startActivity(
                                Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.parse("package:$packageName"),
                                ),
                            )
                            result.success(true)
                        } catch (error: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // A tap that arrived while the engine was not ready yet.
        val pending = pendingSession
        if (pending != null) {
            pendingSession = null
            notifyChannel?.invokeMethod("open-session", pending)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val sessionId = sessionFrom(intent) ?: return
        // Drop the marker so a rotation or relaunch cannot replay the same tap.
        intent.removeExtra(EXTRA_SESSION_ID)
        intent.data = null
        val channel = notifyChannel
        if (channel == null) {
            pendingSession = sessionId
            return
        }
        channel.invokeMethod("open-session", sessionId)
    }

    /// Accepts either the extra or the session data URI. Extras can be dropped
    /// when the OS restores a task instead of launching our intent; the URI
    /// rides along with the PendingIntent's data field.
    private fun sessionFrom(intent: Intent?): String? {
        val extra = intent?.getStringExtra(EXTRA_SESSION_ID)
        if (!extra.isNullOrEmpty()) return extra
        val data = intent?.data ?: return null
        if (data.scheme != "dsh" || data.host != "session") return null
        return data.lastPathSegment
    }

    /// HyperOS/Android asks once; when the system refuses the direct dialog the
    /// user still lands on the battery list.
    private fun openIgnoreBatteryOptimizations(): Boolean {
        return try {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName"),
                ),
            )
            true
        } catch (error: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                true
            } catch (inner: Exception) {
                false
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
            description = "任务完成与会话提醒"
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

    private fun show(title: String, body: String, sessionId: String?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            if (sessionId != null) {
                putExtra(EXTRA_SESSION_ID, sessionId)
                data = Uri.parse("dsh://session/$sessionId")
            }
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val contentIntent = PendingIntent.getActivity(
            this,
            sessionId?.hashCode() ?: 0,
            intent,
            flags,
        )
        val notification = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .build()
        // One live notification per session: a later completion replaces the
        // earlier one instead of stacking up.
        val id = sessionId?.hashCode() ?: nextNotificationId++
        NotificationManagerCompat.from(this).notify(id, notification)
    }

    private companion object {
        const val EXTRA_SESSION_ID = "dshSessionId"
    }
}
