import Foundation

/// The tabs of a folder window, in order, and which one is shown.
/// New tabs go right after the current one; closing the current tab shows
/// the one that takes its place, or the one before it at the end.
struct TabList<Element: Identifiable> {
    private(set) var items: [Element] = []
    private(set) var currentID: Element.ID?

    var current: Element? { currentID.flatMap { id in items.first { $0.id == id } } }
    var currentIndex: Int? { currentID.flatMap { id in items.firstIndex { $0.id == id } } }
    var isEmpty: Bool { items.isEmpty }

    /// Adds a tab right after the current one (at the end when there is none).
    /// The new tab becomes the current one unless `inBackground`.
    mutating func insert(_ element: Element, inBackground: Bool = false) {
        let index = currentIndex.map { $0 + 1 } ?? items.count
        items.insert(element, at: index)
        if !inBackground || currentID == nil { currentID = element.id }
    }

    /// Adds a tab at the end, without showing it unless there is no current
    /// tab (restoring the tabs of a window).
    mutating func append(_ element: Element) {
        items.append(element)
        if currentID == nil { currentID = element.id }
    }

    /// Shows the tab with this identifier, if there is one.
    mutating func select(_ id: Element.ID) {
        guard items.contains(where: { $0.id == id }) else { return }
        currentID = id
    }

    /// Shows the next (or previous) tab, wrapping around.
    mutating func selectNeighbour(offset: Int) {
        guard let index = currentIndex, !items.isEmpty else { return }
        let next = ((index + offset) % items.count + items.count) % items.count
        currentID = items[next].id
    }

    /// Removes a tab and returns it.
    @discardableResult
    mutating func remove(_ id: Element.ID) -> Element? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = items.remove(at: index)
        if currentID == id {
            currentID = items.isEmpty ? nil : items[min(index, items.count - 1)].id
        }
        return removed
    }

    /// Moves a tab to `destination`, an index of the final order.
    mutating func move(_ id: Element.ID, to destination: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let element = items.remove(at: index)
        items.insert(element, at: min(max(destination, 0), items.count))
    }
}
