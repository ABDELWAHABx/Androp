package app.androp.android.utils

/** One failing platform cleanup must not keep unrelated sockets, services or timers alive. */
internal fun runShutdownSteps(
    steps: List<Pair<String, () -> Unit>>,
    onFailure: (String, Exception) -> Unit
) {
    for ((name, stop) in steps) {
        try { stop() } catch (error: Exception) { onFailure(name, error) }
    }
}
