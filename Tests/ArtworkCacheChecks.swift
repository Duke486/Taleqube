// Disk-policy checks use the production PosterCache actor with platform image stubs.
// Image decoding and SwiftUI are covered by the iOS build, not these filesystem checks.
import Foundation
import CryptoKit

final class UIImage: @unchecked Sendable {
    init?(data:Data) { if data.isEmpty { return nil } }
    var cgImage: Bitmap? { nil }
    func preparingForDisplay() -> UIImage? { self }
    struct Bitmap { var bytesPerRow:Int; var height:Int }
}
actor DiagnosticLog {
    static let shared = DiagnosticLog()
    func record(_ level:String,component:String,message:String) {}
}
let testRoot = URL.temporaryDirectory.appending(path:"Taleqube-artwork-check-" + UUID().uuidString)

// PRODUCTION_CACHE

extension PosterCache {
    func checkDiskPolicy() throws {
        let fm = FileManager.default
        defer { try? fm.removeItem(at:testRoot); UserDefaults.standard.removeObject(forKey:Self.limitKey) }
        try fm.createDirectory(at:directory,withIntermediateDirectories:true)
        try preparePreferredDirectory()
        // macOS temporary directories do not report the iOS backup exclusion flag.
        let cover = "https://example.com/cover", still = "https://example.com/still", episode = "https://example.com/episode"
        let oldCover = directory.appending(path:key(for:cover))
        try Data(repeating:1,count:600_000).write(to:oldCover)
        try register(cover,retention:.preferred)
        precondition(!fm.fileExists(atPath:oldCover.path))
        precondition(fm.fileExists(atPath:file(for:key(for:cover)).path))
        precondition(diskBytes == 600_000)
        try register(cover,retention:.standard)
        precondition(file(for:key(for:cover)).deletingLastPathComponent().path == preferredDirectory.path)
        // Reloading the disk index retains the classification across process launches.
        diskEntries = nil; preferredKeys.removeAll(); loadDiskIndex()
        precondition(preferredKeys.contains(key(for:cover)))
        for (address,date) in [(still,Date(timeIntervalSince1970:200)),(episode,Date(timeIntervalSince1970:300))] {
            let path = file(for:key(for:address))
            try Data(repeating:2,count:300_000).write(to:path)
            rememberFile(path,size:300_000,date:date)
        }
        // The cover is oldest but must outlive both ordinary images.
        rememberFile(file(for:key(for:cover)),size:600_000,date:Date(timeIntervalSince1970:100))
        try setLimit(megabytes:1)
        precondition(!fm.fileExists(atPath:file(for:key(for:still)).path))
        precondition(fm.fileExists(atPath:file(for:key(for:episode)).path))
        precondition(fm.fileExists(atPath:file(for:key(for:cover)).path))
        precondition(diskBytes == 900_000)
        touch(cover)
        precondition(diskEntries?[file(for:key(for:cover))]?.date ?? .distantPast > Date(timeIntervalSince1970:300))
        owners["work"] = [cover]; try saveOwners()
        try remove([],owners:["work"])
        precondition(!fm.fileExists(atPath:preferredDirectory.appending(path:key(for:cover)).path))
        precondition(diskBytes == 300_000)
        try setLimit(megabytes:0)
        precondition(diskBytes == 0)
        try clear()
        precondition(!fm.fileExists(atPath:preferredDirectory.path) && !fm.fileExists(atPath:directory.path))
        print("Artwork cache: promotion, restart classification, priority/LRU eviction, access refresh, owner removal, zero limit and clear passed")
    }
}
@main struct Checks {
    static func main() async throws { try await PosterCache().checkDiskPolicy() }
}
