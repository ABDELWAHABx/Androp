package app.androp.android.utils

/** Pure rules shared by publishing and executing mirrored Android notification actions. */
object NotificationActionPolicy {
    data class Action(val name: String, val supportsReply: Boolean)

    /** The wire protocol addresses actions by title, so duplicate titles are unsafe to expose. */
    fun unambiguousIndices(actions: List<Action>): List<Int> = actions.indices.filter { index ->
        val name = actions[index].name
        name.isNotBlank() && actions.count { it.name.equals(name, ignoreCase = true) } == 1
    }

    fun selectAction(actions: List<Action>, name: String, replyText: String?): Int? {
        val index = unambiguousIndices(actions).singleOrNull {
            actions[it].name.equals(name, ignoreCase = true)
        } ?: return null
        val reply = replyText?.takeIf { it.isNotEmpty() }
        // An empty reply must never invoke the underlying PendingIntent as a button.
        if (actions[index].supportsReply != (reply != null)) return null
        if (reply != null && (reply.isBlank() || reply.length > 16_384)) return null
        return index
    }

    /** Recover only an exact registered ID, never a package/title or timestamp heuristic. */
    fun resolveKey(id: String, activeKeys: Set<String>, mappings: Map<String, String>): String? =
        mappings.entries.singleOrNull { it.value == id && it.key in activeKeys }?.key
}
