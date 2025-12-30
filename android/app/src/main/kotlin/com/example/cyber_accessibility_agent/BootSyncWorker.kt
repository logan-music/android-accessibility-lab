package com.example.cyber_accessibility_agent

import android.content.Context
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters
import org.json.JSONObject
import java.io.BufferedOutputStream
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.time.Instant

class BootSyncWorker(appContext: Context, workerParams: WorkerParameters) : Worker(appContext, workerParams) {
    companion object {
        private const val TAG = "BootSyncWorker"

        // Replace with your project's values (anon key is okay)
        private const val SUPABASE_PROJECT_URL = "https://pbovhvhpewnooofaeybe.supabase.co"
        private const val SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBib3ZodmhwZXdub29vZmFleWJlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjYxNjY0MTIsImV4cCI6MjA4MTc0MjQxMn0.5MotbwR5oS29vZ2w-b2rmyExT1M803ImLD_-ecu2MzU"
    }

    override fun doWork(): Result {
        try {
            // Flutter SharedPreferences live in "FlutterSharedPreferences"
            val prefs = applicationContext.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val deviceId = prefs.getString("device_id", null)
            if (deviceId.isNullOrBlank()) {
                Log.w(TAG, "no device_id in FlutterSharedPreferences — skipping")
                return Result.success()
            }

            // Build upsert body; mark offline on boot, update last_seen
            val bodyJson = JSONObject().apply {
                put("id", deviceId)
                put("online", false)
                put("last_seen", Instant.now().toString())
            }.toString()

            val url = URL("$SUPABASE_PROJECT_URL/rest/v1/devices")
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 8_000
                readTimeout = 8_000
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("apikey", SUPABASE_ANON_KEY)
                setRequestProperty("Authorization", "Bearer $SUPABASE_ANON_KEY")
                // use resolution=merge-duplicates to upsert
                setRequestProperty("Prefer", "return=representation, resolution=merge-duplicates")
            }

            BufferedOutputStream(conn.outputStream).use { os ->
                OutputStreamWriter(os, "UTF-8").use { it.write(bodyJson) }
            }

            val code = conn.responseCode
            val respMsg = conn.inputStream.bufferedReader().use { it.readText() }
            if (code >= 200 && code < 300) {
                Log.i(TAG, "boot sync ok for $deviceId (code=$code)")
                return Result.success()
            } else {
                Log.w(TAG, "boot sync failed code=$code msg=$respMsg")
                return Result.retry()
            }
        } catch (t: Throwable) {
            Log.e(TAG, "boot sync error: ${t.message}", t)
            // transient network error -> retry
            return Result.retry()
        }
    }
}