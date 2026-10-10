package app.androp.android.utils

/** Remembers successful sends per identity, without retaining an unbounded history. */
class BoundedValueCache<K, V>(private val capacity: Int) {
    init { require(capacity > 0) }
    private val values = LinkedHashMap<K, V>(capacity, 0.75f, true)

    @Synchronized fun matches(key: K, value: V): Boolean = values[key] == value
    @Synchronized fun remember(key: K, value: V) {
        values[key] = value
        while (values.size > capacity) values.remove(values.keys.first())
    }
    @Synchronized fun remove(key: K) { values.remove(key) }
    @Synchronized fun clear() { values.clear() }
}
