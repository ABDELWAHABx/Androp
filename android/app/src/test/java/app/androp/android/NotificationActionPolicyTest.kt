package app.androp.android

import app.androp.android.utils.NotificationActionPolicy
import app.androp.android.utils.NotificationActionPolicy.Action
import org.junit.Assert.*
import org.junit.Test

class NotificationActionPolicyTest {
    @Test fun absentOrEmptyTextInvokesRealButton() {
        val actions = listOf(Action("Mark as read", false))
        assertEquals(0, NotificationActionPolicy.selectAction(actions, "Mark as read", null))
        assertEquals(0, NotificationActionPolicy.selectAction(actions, "Mark as read", ""))
    }

    @Test fun replyRequiresNonBlankText() {
        val actions = listOf(Action("Reply", true))
        assertNull(NotificationActionPolicy.selectAction(actions, "Reply", null))
        assertNull(NotificationActionPolicy.selectAction(actions, "Reply", ""))
        assertNull(NotificationActionPolicy.selectAction(actions, "Reply", " \n"))
        assertEquals(0, NotificationActionPolicy.selectAction(actions, "Reply", "Hello"))
    }

    @Test fun textCannotBeSentToPlainButton() {
        assertNull(NotificationActionPolicy.selectAction(listOf(Action("Mute", false)), "Mute", "Hello"))
    }

    @Test fun ambiguousDuplicateNamesAreNotPublishedOrInvoked() {
        val actions = listOf(Action("Reply", true), Action("REPLY", false), Action("Read", false))
        assertEquals(listOf(2), NotificationActionPolicy.unambiguousIndices(actions))
        assertNull(NotificationActionPolicy.selectAction(actions, "Reply", "Hello"))
        assertNull(NotificationActionPolicy.selectAction(actions, "REPLY", null))
    }

    @Test fun unnamedAndInventedActionsAreRejected() {
        val actions = listOf(Action(" ", false), Action("Mute", false))
        assertEquals(listOf(1), NotificationActionPolicy.unambiguousIndices(actions))
        assertNull(NotificationActionPolicy.selectAction(actions, "Mark as read", null))
    }

    @Test fun oversizedRepliesAreRejected() {
        assertNull(NotificationActionPolicy.selectAction(listOf(Action("Reply", true)), "Reply", "a".repeat(16_385)))
    }

    @Test fun restoredPersistedMappingResolvesExactLiveKey() {
        assertEquals("android-key", NotificationActionPolicy.resolveKey("legacy_id_123", setOf("android-key"),
            mapOf("android-key" to "legacy_id_123")))
    }

    @Test fun staleMissingNotificationNeverMatchesAnotherNotification() {
        assertNull(NotificationActionPolicy.resolveKey("old", setOf("new-key"),
            mapOf("old-key" to "old", "new-key" to "new")))
    }

    @Test fun ambiguousLegacyIdCollisionIsRejected() {
        assertNull(NotificationActionPolicy.resolveKey("same-title-time-id", setOf("one", "two"),
            mapOf("one" to "same-title-time-id", "two" to "same-title-time-id")))
    }

    @Test fun titleOrPackageResemblanceDoesNotAuthorizeAnAction() {
        assertNull(NotificationActionPolicy.resolveKey("package_title_100", setOf("one"),
            mapOf("one" to "package_title_101")))
    }
}
