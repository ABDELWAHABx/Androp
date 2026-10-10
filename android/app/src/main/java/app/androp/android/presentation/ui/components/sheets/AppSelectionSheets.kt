package app.androp.android.presentation.ui.components.sheets

import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import app.androp.android.R
import app.androp.android.domain.model.NotificationApp
import app.androp.android.utils.HapticUtil
import app.androp.android.utils.AppSelectionPolicy

@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun AppSelectionSheet(
    onDismissRequest: () -> Unit,
    apps: List<NotificationApp>,
    onAppToggle: (String, Boolean) -> Unit,
    onSaveAll: (List<NotificationApp>) -> Unit,
    isLoading: Boolean,
    onBulkToggle: ((Set<String>, Boolean) -> Unit)? = null
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val haptics = LocalHapticFeedback.current
    var searchQuery by remember { mutableStateOf("") }
    var showSystemApps by remember { mutableStateOf(false) }

    val filteredApps = remember(apps, searchQuery, showSystemApps) {
        AppSelectionPolicy.visible(apps, searchQuery, showSystemApps)
    }
    val setVisibleEnabled: (Boolean) -> Unit = { enabled ->
        HapticUtil.performClick(haptics)
        val packages = filteredApps.mapTo(mutableSetOf()) { it.packageName }
        if (onBulkToggle != null) onBulkToggle(packages, enabled)
        else onSaveAll(AppSelectionPolicy.setEnabled(apps, packages, enabled))
    }

    ModalBottomSheet(
        onDismissRequest = onDismissRequest,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surfaceContainerHigh
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .fillMaxHeight(0.9f)
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = stringResource(R.string.action_select_apps),
                    style = MaterialTheme.typography.headlineSmall
                )

            }

            // Search Bar
            OutlinedTextField(
                value = searchQuery,
                onValueChange = { searchQuery = it },
                modifier = Modifier.fillMaxWidth(),
                placeholder = { Text("Search apps") },
                leadingIcon = {
                    Icon(
                        painter = painterResource(id = R.drawable.outline_info_24), // Fallback search icon
                        contentDescription = "Search"
                    )
                },
                singleLine = true,
                shape = RoundedCornerShape(12.dp)
            )

            // System Apps Toggle
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .toggleable(value = showSystemApps, role = Role.Switch) { checked ->
                        HapticUtil.performClick(haptics)
                        showSystemApps = checked
                    }
                    .padding(8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Icon(
                    painter = painterResource(id = R.drawable.rounded_android_24),
                    contentDescription = null,
                    modifier = Modifier.size(24.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Text(
                    text = "Show system apps",
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.weight(1f),
                    color = MaterialTheme.colorScheme.onSurface
                )
                Switch(
                    checked = showSystemApps,
                    onCheckedChange = null
                )
            }

            Column {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = { setVisibleEnabled(true) }, enabled = !isLoading && filteredApps.any { !it.isEnabled }) {
                        Text("Select all shown")
                    }
                    TextButton(onClick = { setVisibleEnabled(false) }, enabled = !isLoading && filteredApps.any { it.isEnabled }) {
                        Text("Deselect all shown")
                    }
                }
                Text(
                    text = "${filteredApps.count { it.isEnabled }} of ${filteredApps.size} shown selected",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            if (isLoading) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 32.dp),
                    horizontalArrangement = Arrangement.Center
                ) {
                    CircularProgressIndicator()
                }
            } else if (filteredApps.isEmpty()) {
                Text("No matching apps", modifier = Modifier.weight(1f).padding(16.dp))
            } else {
                LazyColumn(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(24.dp)),
                    verticalArrangement = Arrangement.spacedBy(2.dp)
                ) {
                    items(filteredApps, key = { it.packageName }) { app ->
                        AppToggleItem(
                            icon = app.icon,
                            title = app.appName,
                            packageName = app.packageName,
                            isSystemApp = app.isSystemApp,
                            isChecked = app.isEnabled,
                            onCheckedChange = { isChecked ->
                                HapticUtil.performClick(haptics)
                                onAppToggle(app.packageName, isChecked)
                            }
                        )
                    }
                }
            }
            Spacer(modifier = Modifier.height(16.dp))
        }
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun AppToggleItem(
    icon: Any?,
    title: String,
    modifier: Modifier = Modifier,
    description: String? = null,
    packageName: String? = null,
    isSystemApp: Boolean = false,
    isChecked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    enabled: Boolean = true
) {
    val haptics = LocalHapticFeedback.current
    val shouldShowSystemTag = isSystemApp

    ListItem(
        modifier = modifier
            .fillMaxWidth()
            .toggleable(value = isChecked, enabled = enabled, role = Role.Switch) { checked ->
                HapticUtil.performClick(haptics)
                onCheckedChange(checked)
            },
        leadingContent = {
            if (icon != null) {
                AsyncImage(
                    model = icon,
                    contentDescription = title,
                    modifier = Modifier
                        .size(32.dp)
                        .clip(RoundedCornerShape(8.dp))
                )
            } else {
                Spacer(modifier = Modifier.size(32.dp))
            }
        },
        headlineContent = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface
                )
                if (shouldShowSystemTag) {
                    Icon(
                        painter = painterResource(id = R.drawable.rounded_android_24),
                        contentDescription = "System App",
                        modifier = Modifier.size(14.dp),
                        tint = MaterialTheme.colorScheme.primary
                    )
                }
            }
        },
        supportingContent = if (description != null) {
            {
                Text(
                    text = description,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        } else null,
        trailingContent = {
            Switch(
                checked = if (enabled) isChecked else false,
                onCheckedChange = null,
                enabled = enabled
            )
        },
        colors = ListItemDefaults.colors(
            containerColor = MaterialTheme.colorScheme.surfaceBright
        )
    )
}
