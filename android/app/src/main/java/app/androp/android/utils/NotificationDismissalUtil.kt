package app.androp.android.utils

import android.app.RemoteInput
import android.content.Intent
import android.os.Bundle
import android.service.notification.StatusBarNotification
import android.util.Log
import app.androp.android.service.MediaNotificationListener
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

object NotificationDismissalUtil {
    private const val TAG = "NotificationDismissalUtil"
    private const val ID_MAP_PREFS = "notification_id_mappings"
    private val keyToId = ConcurrentHashMap<String, String>()
    private val suppressedIds = ConcurrentHashMap.newKeySet<String>()
    private val testNotificationIds = ConcurrentHashMap.newKeySet<String>()

    // Legacy format is retained for synthetic test notifications only.
    fun generateNotificationId(packageName: String, title: String, timestamp: Long): String =
        "${packageName}_${title.hashCode()}_$timestamp"

    /** One opaque ID per notification lifetime, preserved across updates and process restarts. */
    @Synchronized
    fun registerNotification(notification: StatusBarNotification): String {
        val id = getIdBySystemKey(notification.key) ?: getPersistedIdBySystemKey(notification.key)
            ?: "notification_${UUID.randomUUID()}"
        storeNotification(id, notification)
        return id
    }

    @Synchronized
    fun storeNotification(id: String, notification: StatusBarNotification) {
        val previous = keyToId.put(notification.key, id)
        if (previous != id && getPersistedIdBySystemKey(notification.key) != id) {
            idMapPrefs()?.edit()?.putString(notification.key, id)?.apply()
        }
    }

    fun storeTestNotificationId(id: String) {
        if (testNotificationIds.size >= 200) testNotificationIds.clear()
        testNotificationIds.add(id)
    }

    /** Always use the current system notification and PendingIntents, never a cached snapshot. */
    private fun resolveNotification(notificationId: String): StatusBarNotification? {
        val service = MediaNotificationListener.getInstance() ?: return null
        val current = service.activeNotifications?.toList().orEmpty()
        val mappings = idMapPrefs()?.all.orEmpty().mapNotNull { (key, value) ->
            (value as? String)?.let { key to it }
        }.toMap() + keyToId
        val key = NotificationActionPolicy.resolveKey(notificationId, current.map { it.key }.toSet(), mappings)
            ?: return null
        return current.singleOrNull { it.key == key }
    }

    fun dismissNotification(notificationId: String): Boolean = try {
        if (BackgroundWorkController.isPaused) false
        else if (testNotificationIds.remove(notificationId)) true
        else {
            val service = MediaNotificationListener.getInstance()
            val notification = resolveNotification(notificationId)
            if (service == null || notification == null || !notification.isClearable) false
            else {
                markSuppressed(notificationId)
                try {
                    service.cancelNotification(notification.key)
                    // Retain the reverse mapping until the removal callback consumes suppression.
                    true
                } catch (e: Exception) {
                    consumeSuppressed(notificationId)
                    throw e
                }
            }
        }
    } catch (e: Exception) {
        Log.w(TAG, "Could not dismiss notification", e)
        false
    }

    fun actionDescriptors(actions: Array<out android.app.Notification.Action>): List<NotificationActionPolicy.Action> =
        actions.map { NotificationActionPolicy.Action(it.title?.toString().orEmpty(),
            it.remoteInputs?.any { input -> input.allowFreeFormInput } == true) }

    fun performNotificationAction(notificationId: String, actionName: String, replyText: String? = null): Boolean {
        if (BackgroundWorkController.isPaused) return false
        return try {
            val service = MediaNotificationListener.getInstance() ?: return false
            val sbn = resolveNotification(notificationId) ?: return false
            val actions = sbn.notification.actions ?: return false
            val index = NotificationActionPolicy.selectAction(actionDescriptors(actions), actionName, replyText)
                ?: return false
            val target = actions[index]
            val pendingIntent = target.actionIntent ?: return false
            if (!replyText.isNullOrEmpty()) {
                val remoteInputs = target.remoteInputs?.filter { it.allowFreeFormInput }?.toTypedArray()
                    ?.takeIf { it.isNotEmpty() } ?: return false
                val intent = Intent()
                val results = Bundle()
                remoteInputs.forEach { results.putCharSequence(it.resultKey, replyText) }
                RemoteInput.addResultsToIntent(remoteInputs, intent, results)
                RemoteInput.setResultsSource(intent, RemoteInput.SOURCE_FREE_FORM_INPUT)
                pendingIntent.send(service, 0, intent)
            } else {
                pendingIntent.send()
            }
            true
        } catch (e: Exception) {
            Log.w(TAG, "Could not perform notification action", e)
            false
        }
    }

    fun getIdBySystemKey(systemKey: String): String? = keyToId[systemKey]

    fun getPersistedIdBySystemKey(systemKey: String): String? = try {
        idMapPrefs()?.getString(systemKey, null)
    } catch (_: Exception) { null }

    @Synchronized
    fun prunePersistedMappings(activeKeys: Set<String>) {
        keyToId.keys.removeAll { it !in activeKeys }
        try {
            val prefs = idMapPrefs() ?: return
            val editor = prefs.edit()
            prefs.all.keys.filter { it !in activeKeys }.forEach { editor.remove(it) }
            editor.apply()
            val liveIds = keyToId.values.toSet()
            suppressedIds.retainAll(liveIds)
        } catch (e: Exception) { Log.w(TAG, "Could not prune notification mappings", e) }
    }

    private fun idMapPrefs(): android.content.SharedPreferences? =
        MediaNotificationListener.getInstance()?.applicationContext
            ?.getSharedPreferences(ID_MAP_PREFS, android.content.Context.MODE_PRIVATE)

    fun getIdForSbn(sbn: StatusBarNotification?): String? = sbn?.key?.let {
        getIdBySystemKey(it) ?: getPersistedIdBySystemKey(it)
    }

    fun markSuppressed(notificationId: String) { suppressedIds.add(notificationId) }
    fun consumeSuppressed(notificationId: String): Boolean = suppressedIds.remove(notificationId)

    @Synchronized
    fun removeFromCaches(id: String) {
        val keys = keyToId.entries.filter { it.value == id }.map { it.key }.toMutableSet()
        val prefs = idMapPrefs()
        prefs?.all?.filterValues { it == id }?.keys?.let(keys::addAll)
        val editor = prefs?.edit()
        keys.forEach { keyToId.remove(it); editor?.remove(it) }
        editor?.apply()
        suppressedIds.remove(id)
        testNotificationIds.remove(id)
    }
}
