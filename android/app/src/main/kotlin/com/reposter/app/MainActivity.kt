package com.reposter.app

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "reposter/share",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "shareToTarget" -> {
                    val filePath = call.argument<String>("filePath")
                    val packageName = call.argument<String>("packageName")
                    val caption = call.argument<String>("caption")

                    if (filePath.isNullOrBlank() || packageName.isNullOrBlank()) {
                        result.error("BAD_ARGS", "Missing filePath or packageName.", null)
                        return@setMethodCallHandler
                    }

                    try {
                        shareToTarget(
                            filePath = filePath,
                            packageName = packageName,
                            caption = caption,
                        )
                        result.success(null)
                    } catch (_: ActivityNotFoundException) {
                        result.error("APP_NOT_FOUND", "Install the target app first.", null)
                    } catch (error: Exception) {
                        result.error("SHARE_FAILED", error.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun shareToTarget(
        filePath: String,
        packageName: String,
        caption: String?,
    ) {
        val file = File(filePath)
        require(file.exists()) { "Video file not found." }

        val uri = FileProvider.getUriForFile(
            this,
            "${applicationContext.packageName}.fileprovider",
            file,
        )

        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "video/*"
            setPackage(packageName)
            putExtra(Intent.EXTRA_STREAM, uri)
            if (!caption.isNullOrBlank()) {
                putExtra(Intent.EXTRA_TEXT, caption)
            }
            clipData = ClipData.newUri(contentResolver, file.name, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        startActivity(intent)
    }
}
