package app.androp.android.utils

import java.io.File

/** Keeps file browsing inside shared storage, including when a path contains symlinks. */
internal object StoragePathResolver {
    fun safeFileName(displayName: String, fallback: String): String {
        val name = displayName.replace('\\', '/').substringAfterLast('/').replace('\u0000', '_')
        return if (name.isBlank() || name == "." || name == "..") fallback else name
    }

    fun resolve(root: File, path: String, allowAbsolute: Boolean = false): File? {
        val canonicalRoot = root.canonicalFile
        val candidate = if (allowAbsolute && path.startsWith('/')) File(path) else File(root, path.trimStart('/'))
        val resolved = candidate.canonicalFile
        return resolved.takeIf { it == canonicalRoot || it.path.startsWith(canonicalRoot.path + File.separator) }
    }
}
