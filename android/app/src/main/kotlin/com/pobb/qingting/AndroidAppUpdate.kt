package com.pobb.qingting

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/** Only shares verified update APKs from the application's private update cache. */
object AndroidAppUpdate {
    fun register(activity: Activity, messenger: BinaryMessenger) {
        MethodChannel(messenger, "qingting/app_update").setMethodCallHandler { call, result ->
            if (call.method != "prepareInstall" && call.method != "installApk") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                val apk = verifiedApk(activity, call)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    !activity.packageManager.canRequestPackageInstalls()) {
                    activity.startActivity(Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:${activity.packageName}"),
                    ))
                    throw IllegalStateException("请允许青听安装应用，返回后再次点击“安装更新”")
                }
                if (call.method == "installApk") {
                    val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", apk)
                    activity.startActivity(Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, "application/vnd.android.package-archive")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    })
                }
                result.success(true)
            } catch (error: Exception) {
                result.error("update_failed", error.message ?: "无法打开系统安装器，请重试", null)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun verifiedApk(activity: Activity, call: MethodCall): File {
        val path = call.argument<String>("path") ?: error("缺少更新包路径")
        val apk = File(path).canonicalFile
        val cache = File(activity.filesDir, "updates").canonicalFile
        require(apk.isFile && apk.extension == "apk" &&
            apk.path.startsWith(cache.path + File.separator)) { "更新包不在青听更新目录中" }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
        val manager = activity.packageManager
        val incoming = manager.getPackageArchiveInfo(apk.path, flags) ?: error("无法读取 APK 信息")
        val installed = manager.getPackageInfo(activity.packageName, flags)
        require(incoming.packageName == activity.packageName) { "更新包不属于当前青听应用" }
        val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            incoming.longVersionCode
        } else {
            incoming.versionCode.toLong()
        }
        require(incoming.versionName == call.argument<String>("versionName") &&
            versionCode == call.argument<Number>("versionCode")?.toLong()) { "APK 版本与更新信息不一致" }
        val trusted = signatures(installed)
        require(trusted.isNotEmpty() && signatures(incoming) == trusted) { "APK 签名与当前安装的青听不一致" }
        return apk
    }

    @Suppress("DEPRECATION")
    private fun signatures(info: PackageInfo): Set<String> {
        val signers = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners
        } else {
            info.signatures
        }
        return signers.orEmpty().map { signature ->
            MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
                .joinToString("") { "%02x".format(it) }
        }.toSet()
    }
}
