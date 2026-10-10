import app.androp.android.utils.StoragePathResolver
import android.os.Environment
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

object FileBrowserUtil {
    private const val TAG = "FileBrowserUtil"
    private val ROOT_PATH = Environment.getExternalStorageDirectory().absolutePath

    fun listDirectory(path: String?, showHidden: Boolean = false): String {
        var targetPath = if (path.isNullOrBlank()) ROOT_PATH else path
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R &&
            !Environment.isExternalStorageManager()) {
            return createErrorResponse(targetPath,
                "To browse your phone from the Mac, enable File Access in androp on your phone and allow All files access in Android Settings. Sending and receiving files in Downloads does not need this permission.")
        }

        if (!targetPath.startsWith("/")) {
            targetPath = ROOT_PATH + (if (targetPath.startsWith("/")) "" else "/") + targetPath
        }

        val directory = StoragePathResolver.resolve(File(ROOT_PATH), targetPath, allowAbsolute = true)
            ?: return createErrorResponse(targetPath, "Path is outside shared storage")
        targetPath = directory.path
        val restricted = listOf(File(ROOT_PATH, "Android/data").canonicalFile, File(ROOT_PATH, "Android/obb").canonicalFile)
        if (restricted.any { directory == it || directory.path.startsWith(it.path + File.separator) }) {
            return createErrorResponse(targetPath,
                "Android protects other apps' data and obb folders, even with All files access. Browse Downloads, Documents, or DCIM instead.")
        }

        if (!directory.exists()) {
            Log.e(TAG, "Directory does not exist: $targetPath")
            return createErrorResponse(targetPath, "Directory does not exist")
        }

        if (!directory.isDirectory) {
            Log.e(TAG, "Not a directory: $targetPath")
            return createErrorResponse(targetPath, "Not a directory")
        }

        val items = directory.listFiles()
        if (items == null) {
            Log.e(TAG, "Access denied or I/O error for: $targetPath")
            return createErrorResponse(
                targetPath,
                "Access denied. Please ensure 'All Files Access' permission is granted."
            )
        }

        val jsonItems = JSONArray()
        for (file in items.sortedWith(compareBy({ !it.isDirectory }, { it.name.lowercase() }))) {
            if (!showHidden && file.name.startsWith(".") && file.name != ".") {
                continue
            }
            val item = JSONObject()
            item.put("name", file.name)
            item.put("isDir", file.isDirectory)
            item.put("size", if (file.isDirectory) 0 else file.length())
            item.put("time", file.lastModified())
            jsonItems.put(item)
        }

        val data = JSONObject()
        data.put("path", targetPath)
        data.put("items", jsonItems)

        val response = JSONObject()
        response.put("type", "browseData")
        response.put("data", data)

        return response.toString()
    }

    private fun createErrorResponse(path: String, message: String): String {
        val data = JSONObject()
        data.put("path", path)
        data.put("error", message)
        data.put("items", JSONArray())

        val response = JSONObject()
        response.put("type", "browseData")
        response.put("data", data)

        return response.toString()
    }
}
