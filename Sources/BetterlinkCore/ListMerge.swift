import Foundation

/// Saving a list a sheet edited, without losing changes made elsewhere (the
/// CLI, another Mac through a synced folder) while the sheet was open.
///
/// `base` is the list the sheet opened with, `mine` is what the sheet holds at
/// Done, and `theirs` is what is on disk now. Items are matched by `id`:
/// - the sheet's order and its edits win;
/// - an item the sheet left untouched takes the version on disk, and is gone
///   when it was deleted there;
/// - an item the sheet deleted stays deleted;
/// - an item added elsewhere is kept, after the sheet's items.
public enum ListMerge {
    public static func merge<T: Identifiable & Equatable>(base: [T], mine: [T], theirs: [T]) -> [T] {
        let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let theirsByID = Dictionary(theirs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mineIDs = Set(mine.map(\.id))
        var result: [T] = []
        for item in mine {
            guard let original = baseByID[item.id] else { result.append(item); continue }   // added in the sheet
            if item != original { result.append(item); continue }                          // edited in the sheet
            if let current = theirsByID[item.id] { result.append(current) }                 // untouched: disk's version
        }
        for item in theirs where baseByID[item.id] == nil && !mineIDs.contains(item.id) {
            result.append(item)                                                              // added elsewhere
        }
        return result
    }
}
