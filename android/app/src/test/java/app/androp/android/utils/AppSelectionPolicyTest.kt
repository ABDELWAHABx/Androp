package app.androp.android.utils

import app.androp.android.domain.model.NotificationApp
import org.junit.Assert.*
import org.junit.Test

class AppSelectionPolicyTest {
    private val apps = listOf(
        NotificationApp("com.chat", "Chat", true),
        NotificationApp("com.music", "Music", false),
        NotificationApp("com.hidden", "Hidden", false, isSystemApp = true),
        NotificationApp("com.system", "System", true, isSystemApp = true)
    )

    @Test fun bulkSearchChangesOnlyVisibleMatchingApps() {
        val visible = AppSelectionPolicy.visible(apps, " CHAT ", false)
        val result = AppSelectionPolicy.setEnabled(apps, visible.map { it.packageName }.toSet(), false)
        assertFalse(result[0].isEnabled)
        assertEquals(apps.drop(1), result.drop(1))
    }

    @Test fun hiddenSystemAppsRemainUnchangedWhenSelectingAllVisible() {
        val visible = AppSelectionPolicy.visible(apps, "", false)
        val result = AppSelectionPolicy.setEnabled(apps, visible.map { it.packageName }.toSet(), true)
        assertFalse(result.single { it.packageName == "com.hidden" }.isEnabled)
        assertTrue(result.single { it.packageName == "com.music" }.isEnabled)
    }

    @Test fun selectedSystemAppsStayVisibleAndCanBeDeselected() {
        assertTrue(AppSelectionPolicy.visible(apps, "", false).any { it.packageName == "com.system" })
        assertEquals(4, AppSelectionPolicy.visible(apps, "", true).size)
    }

    @Test fun packageSearchAndEmptyResultsAreSafe() {
        assertEquals("com.music", AppSelectionPolicy.visible(apps, "com.music", false).single().packageName)
        val empty = AppSelectionPolicy.visible(apps, "not-installed", true)
        assertTrue(empty.isEmpty())
        assertEquals(apps, AppSelectionPolicy.setEnabled(apps, emptySet(), false))
    }

    @Test fun togglingSelectionDoesNotReorderRows() {
        val first = AppSelectionPolicy.visible(apps, "", true).map { it.packageName }
        val updated = AppSelectionPolicy.setEnabled(apps, setOf("com.music"), true)
        assertEquals(first, AppSelectionPolicy.visible(updated, "", true).map { it.packageName })
    }
}
