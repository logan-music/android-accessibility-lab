package com.example.cyber_accessibility_agent

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import java.io.*

object FileHelpers {
    private const val TAG = "FileHelpers"

    fun readBytesFromContentUri(context: Context, uri: Uri): ByteArray? {
        return try {
            context.contentResolver.openInputStream(uri)?.use { input ->
                val buffer = ByteArrayOutputStream()
                val tmp = ByteArray(8192)
                var read: Int
                while (input.read(tmp).also { read = it } != -1) {
                    buffer.write(tmp, 0, read)
                }
                buffer.toByteArray()
            }
        } catch (e: Exception) {
            Log.w(TAG, "readBytesFromContentUri failed: ${e.message}", e)
            null
        }
    }

    fun getContentUriMeta(context: Context, uri: Uri): Map<String, Any?> {
        val resolver: ContentResolver = context.contentResolver
        val meta = mutableMapOf<String, Any?>()
        try {
            resolver.query(uri, null, null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val nameIdx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIdx = c.getColumnIndex(OpenableColumns.SIZE)
                    val name = if (nameIdx >= 0) c.getString(nameIdx) else null
                    val size = if (sizeIdx >= 0) c.getLong(sizeIdx) else null
                    meta["display_name"] = name
                    meta["size"] = size
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "getContentUriMeta failed: ${e.message}", e)
        }
        return meta
    }

    // copyInputStreamToFile - useful if native needs to write cache file
    fun copyStreamToFile(input: InputStream, dest: File): Boolean {
        return try {
            dest.outputStream().use { output ->
                input.copyTo(output)
            }
            true
        } catch (e: Exception) {
            Log.w(TAG, "copyStreamToFile failed: ${e.message}", e)
            false
        }
    }
}