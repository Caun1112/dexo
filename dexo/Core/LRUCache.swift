import Foundation

/// A small, in-memory LRU cache. Most-recently-accessed entries stay; the
/// oldest are evicted once the count crosses `capacity`.
///
/// Why not `NSCache`: NSCache evicts on its own schedule (memory warnings,
/// system pressure heuristics) and gives no fine-grained control. When the
/// goal is "cap how much we hold so the heap stops growing during normal use"
/// — which is exactly what `TopicDetailViewController.contentViewCache`
/// needs — strict count-bounded LRU with an eviction callback is much easier
/// to reason about.
///
/// Not thread-safe. All access must happen on the same actor (typically the
/// main actor, which is the project default).
final class LRUCache<Key: Hashable, Value> {
    private let capacity: Int
    private var storage: [Key: Value] = [:]
    /// Front = least-recently-used, back = most-recently-used.
    private var order: [Key] = []

    /// Called when a key/value is evicted (capacity overflow or explicit
    /// removal via `self[key] = nil`). Not called by `removeAll()`.
    var onEvict: ((Key, Value) -> Void)?

    init(capacity: Int) {
        precondition(capacity > 0, "LRUCache capacity must be positive")
        self.capacity = capacity
    }

    // Explicit deinit works around a Swift 6.3 SIL EarlyPerfInliner crash
    // on the synthesized deinit of this generic class under -O WMO (Xcode Cloud archive).
    deinit {}

    subscript(key: Key) -> Value? {
        get {
            guard let value = storage[key] else { return nil }
            // Mark as recently used.
            if let i = order.firstIndex(of: key) {
                order.remove(at: i)
                order.append(key)
            }
            return value
        }
        set {
            if let newValue {
                if storage[key] != nil, let i = order.firstIndex(of: key) {
                    order.remove(at: i)
                }
                storage[key] = newValue
                order.append(key)
                while order.count > capacity {
                    let evictedKey = order.removeFirst()
                    if let evictedValue = storage.removeValue(forKey: evictedKey) {
                        onEvict?(evictedKey, evictedValue)
                    }
                }
            } else if let oldValue = storage.removeValue(forKey: key) {
                if let i = order.firstIndex(of: key) {
                    order.remove(at: i)
                }
                onEvict?(key, oldValue)
            }
        }
    }

    /// Drops every entry without firing `onEvict`. Use for full resets
    /// (jump-to-floor, post-reply refresh) where the caller is already
    /// invalidating related caches in lockstep.
    func removeAll() {
        storage.removeAll()
        order.removeAll()
    }

    @discardableResult
    func removeValue(forKey key: Key) -> Value? {
        guard let oldValue = storage.removeValue(forKey: key) else { return nil }
        if let i = order.firstIndex(of: key) {
            order.remove(at: i)
        }
        onEvict?(key, oldValue)
        return oldValue
    }

    var count: Int { storage.count }
}
