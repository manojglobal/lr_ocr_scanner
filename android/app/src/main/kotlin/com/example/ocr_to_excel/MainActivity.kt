package com.example.ocr_to_excel

import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val APP_INFO_CHANNEL = "com.example.ocr_to_excel/app_info"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_INFO_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAppVersion" -> {
                        try {
                            val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                packageManager.getPackageInfo(
                                    packageName,
                                    PackageManager.PackageInfoFlags.of(0)
                                )
                            } else {
                                @Suppress("DEPRECATION")
                                packageManager.getPackageInfo(packageName, 0)
                            }
                            result.success(packageInfo.versionName ?: "")
                        } catch (e: Exception) {
                            result.error("VERSION_ERROR", "Failed to read app version", e.message)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
