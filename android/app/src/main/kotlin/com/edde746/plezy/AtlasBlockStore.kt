// IMPORTANT: change this to the SAME package line that is at the top of your
// PlezyActivity.kt (it is the folder this file sits in).
package com.edde746.plezy

import android.content.Context
import com.google.android.gms.auth.blockstore.Blockstore
import com.google.android.gms.auth.blockstore.RetrieveBytesRequest
import com.google.android.gms.auth.blockstore.StoreBytesData
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Keeps Atlas's device key in Google's Block Store so it survives an uninstall /
 * reinstall (and moves to a new phone through Google's encrypted backup).
 *
 * Every path is best-effort. On devices without Google Play services (Fire TV,
 * some Android TV boxes) every call quietly returns null / false and Atlas falls
 * back to Quick Connect or the recovery code.
 */
object AtlasBlockStore {
  private const val CHANNEL = "atlas/blockstore"

  fun register(engine: FlutterEngine, context: Context) {
    val appContext = context.applicationContext
    MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
      val key = call.argument<String>("key")
      if (key.isNullOrEmpty()) {
        result.success(null)
        return@setMethodCallHandler
      }
      try {
        val client = Blockstore.getClient(appContext)
        when (call.method) {
          "get" -> {
            val request = RetrieveBytesRequest.Builder().setKeys(listOf(key)).build()
            client.retrieveBytes(request)
              .addOnSuccessListener { response ->
                val bytes = response.blockstoreDataMap[key]?.bytes
                result.success(bytes?.toString(Charsets.UTF_8))
              }
              .addOnFailureListener { result.success(null) }
          }
          "put" -> {
            val value = call.argument<String>("value")
            if (value.isNullOrEmpty()) {
              result.success(false)
              return@setMethodCallHandler
            }
            val data = StoreBytesData.Builder()
              .setKey(key)
              .setBytes(value.toByteArray(Charsets.UTF_8))
              // Cloud backup only happens when the phone has a screen lock
              // (end-to-end encryption); otherwise it stays on-device.
              .setShouldBackupToCloud(true)
              .build()
            client.storeBytes(data)
              .addOnSuccessListener { result.success(true) }
              .addOnFailureListener { result.success(false) }
          }
          else -> result.notImplemented()
        }
      } catch (t: Throwable) {
        // No Play services, API too old, etc.
        result.success(if (call.method == "put") false else null)
      }
    }
  }
}
