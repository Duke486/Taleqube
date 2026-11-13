import Foundation

@MainActor final class AsyncLatch {
    private var released = false
    private var waiters:[CheckedContinuation<Void,Never>] = []
    func wait() async { if released { return }; await withCheckedContinuation { waiters.append($0) } }
    func open() { released = true; let current = waiters; waiters = []; current.forEach { $0.resume() } }
}

@MainActor final class RequestFixture {
    static let shared = RequestFixture()
    var held:[DelayedProtocol] = []
    var paths:[String] = []
    var automatic = false
    var heldHost = "api.deepseek.com"
    func start(_ request:DelayedProtocol) {
        paths.append(request.request.url!.path)
        if automatic || request.request.url!.host != heldHost { request.finish() }
        else { held.append(request) }
    }
    func release() { automatic = true; let requests = held; held = []; requests.forEach { $0.finish() } }
}
final class DelayedProtocol:URLProtocol, @unchecked Sendable {
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() { Task { @MainActor in RequestFixture.shared.start(self) } }
    override func stopLoading() {}
    func finish() {
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main struct ConcurrencyChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition:Bool,_ label:String) { precondition(condition,label); count += 1; print("PASS: \(label)") }
        func until(_ condition:() -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !condition() { guard Date() < deadline else { throw APIError.message("Fixture timed out") }; await Task.yield() }
        }
        let slow = AsyncLatch()
        var started = Set<Int>()
        let mapping = Task { try await AIRequestDeadline.map(Array(0..<8),limit:3) { index in
            started.insert(index)
            if index == 0 { await slow.wait() }
            return index * 2
        } }
        try await until { started.count == 8 }
        check(started.contains(7),"Rolling pool schedules later items while the first item is still suspended")
        slow.open()
        let mapped = try await mapping.value
        check(mapped == Array(0..<8).map { $0 * 2 },"Rolling pool preserves input order")

        let slowPlatform = AsyncLatch()
        var startedPlatforms = Set<Catalog>(), finishedPlatforms = Set<Catalog>()
        var failures = Set<Catalog>(), consuming = 0, maxConsuming = 0
        var merged = TrackingRecord(work:Work(source:.tmdb,remoteID:"parallel",kind:.movie,title:"Parallel"),score:9,progress:4)
        let platformRun = Task {
            try await ConcurrentPlatformMatching.run([.anilist,.mal,.bangumi,.trakt],operation:{ platform -> PlatformMatchingOutcome in
                startedPlatforms.insert(platform)
                if platform == .anilist { await slowPlatform.wait() }
                if platform == .mal { throw APIError.message("Fixture provider failure") }
                return .single(Work(source:platform,remoteID:platform.rawValue,kind:.movie,title:platform.title))
            },consume:{ platform,result in
                consuming += 1; maxConsuming = max(maxConsuming,consuming)
                defer { consuming -= 1; finishedPlatforms.insert(platform) }
                await Task.yield()
                switch result {
                case .success(let delta): merged = try delta.applying(to:merged,platform:platform,catalog:nil,replace:false).record
                case .failure: failures.insert(platform)
                }
            })
        }
        try await until { startedPlatforms.count == 4 && finishedPlatforms.count == 3 }
        check(!finishedPlatforms.contains(.anilist) && merged.links["bangumi"] != nil && merged.links["trakt"] != nil,"Fast platforms commit before a slow platform completes")
        slowPlatform.open(); try await platformRun.value
        check(maxConsuming == 1 && failures == [.mal],"Platform commits are serialized and a provider failure is isolated")
        check(merged.links.count == 3 && merged.score == 9 && merged.progress == 4,"Platform deltas retain previously completed links and user tracking")
        merged = try PlatformMatchingOutcome.noEntry("No result").applying(to:merged,platform:.mal,catalog:nil,replace:false).record
        check(merged.hasNoEntry(.mal) && merged.links["anilist"] != nil && merged.links["bangumi"] != nil,"No-entry only changes its own platform")

        var completedBeforeCancel = Set<Catalog>(), stoppedChildren = 0
        let cancelRun = Task {
            try await ConcurrentPlatformMatching.run([.anilist,.bangumi],operation:{ platform -> Int in
                if platform == .anilist {
                    do { try await Task.sleep(for:.seconds(30)) }
                    catch { stoppedChildren += 1; throw error }
                }
                return 1
            },consume:{ platform,result in
                _ = try result.get(); completedBeforeCancel.insert(platform)
            })
        }
        try await until { completedBeforeCancel.contains(.bangumi) }
        cancelRun.cancel()
        do { try await cancelRun.value; preconditionFailure("Cancelled platform group succeeded") } catch is CancellationError { }
        check(completedBeforeCancel == [.bangumi] && stoppedChildren == 1,"Cancelling platform matching stops pending children and retains completed results")

        let permits = RequestPermits(limit:1)
        try await permits.acquire()
        let cancelled = Task { try await permits.acquire(); permits.release() }
        await Task.yield(); cancelled.cancel()
        do { try await cancelled.value; preconditionFailure("Cancelled waiter acquired a permit") } catch is CancellationError { }
        permits.release()
        try await permits.acquire(); permits.release()
        check(true,"Cancelling a queued waiter does not leak the permit")

        let root = URL.temporaryDirectory.appending(path:"Taleqube-concurrency-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedProtocol.self]; configuration.httpMaximumConnectionsPerHost = 64
        let session = URLSession(configuration:configuration)
        let diagnostics = DiagnosticLog(directory:root.appending(path:"diagnostics"))
        let api = CatalogAPI(session:session,credential:{ _ in "fixture" },diagnostics:diagnostics)
        let secondAPI = CatalogAPI(session:session,credential:{ _ in "fixture" },diagnostics:diagnostics)
        let requests = (0..<60).map { index in Task { @MainActor in
            _ = try await (index.isMultiple(of:2) ? api : secondAPI).request("https://api.deepseek.com/limit/\(index)")
        } }
        try await until { RequestFixture.shared.held.count == 30 }
        for _ in 0..<100 { await Task.yield() }
        check(RequestFixture.shared.paths.count == 30,"All API instances share exactly 30 in-flight DeepSeek permits")
        _ = try await api.request("https://api.example.com/independent")
        check(RequestFixture.shared.paths.contains("/independent"),"DeepSeek saturation does not block another provider")
        let cancelledRequest = Task { _ = try await api.request("https://api.deepseek.com/cancelled") }
        await Task.yield(); cancelledRequest.cancel()
        do { try await cancelledRequest.value; preconditionFailure("Cancelled request succeeded") } catch is CancellationError { }
        RequestFixture.shared.release()
        for request in requests { try await request.value }
        check(!RequestFixture.shared.paths.contains("/cancelled") && RequestFixture.shared.paths.filter { $0.hasPrefix("/limit/") }.count == 60,"Queued requests drain and cancelled requests never reach transport")

        let store = TrackingStore(directory:root.appending(path:"store"),api:api)
        let work = Work(source:.tmdb,remoteID:"1",kind:.movie,title:"Movie")
        store.backup.records[work.id] = TrackingRecord(work:work)
        check(await store.persistAsync(),"Async commit succeeds")
        let valid = TrackingRecord(work:Work(source:.tmdb,remoteID:"isolated",kind:.movie,title:"Valid"),score:8)
        var invalid = valid; invalid.progress = -1
        let invalidDraft = invalid
        let overlappingInvalidSave = Task { @MainActor in await store.save(invalidDraft) }
        let validSaved = await store.save(valid)
        _ = await overlappingInvalidSave.value
        check(validSaved && store.libraryRecord(for:valid.work)?.score == 8,"A concurrent validation error does not turn a committed save into failure")
        let recordsRevision = store.backup.recordsRevision
        store.backup.acknowledgedDeliveryErrors = [:]
        check(store.backup.recordsRevision == recordsRevision,"Sync metadata changes preserve the library revision")
        let firstCommit = Task { @MainActor in store.backup.records[work.id]?.progress = 1; return await store.persistAsync() }
        await Task.yield()
        let secondCommit = Task { @MainActor in store.backup.records[work.id]?.progress = 2; return await store.persistAsync() }
        let committedFirst = await firstCommit.value, committedSecond = await secondCommit.value
        check(committedFirst && committedSecond,"Overlapping snapshots commit successfully")
        let reopened = TrackingStore(directory:root.appending(path:"store"),api:api)
        check(reopened.backup.records[work.id]?.progress == 2,"Later snapshots remain durable after overlapping commits")
        RequestFixture.shared.automatic = false
        RequestFixture.shared.heldHost = "api.themoviedb.org"
        var first = TrackingRecord(work:Work(source:.tmdb,remoteID:"101",kind:.movie,title:"First")); first.score = 7
        var second = TrackingRecord(work:Work(source:.tmdb,remoteID:"102",kind:.movie,title:"Second")); second.score = 8
        let firstSync = Task { await store.save(first,synchronize:true) }
        try await until { !RequestFixture.shared.held.isEmpty }
        _ = await store.save(second,synchronize:true)
        check(store.backup.deliveries.contains { $0.target.remoteID == "102" && $0.isPending },"Second save enqueues while the first remote write is suspended")
        RequestFixture.shared.release()
        _ = await firstSync.value
        check(store.backup.deliveries.filter { ["101","102"].contains($0.target.remoteID) }.allSatisfy { $0.state == "已同步" },"Worker automatically drains jobs submitted during another sync")
        check(RequestFixture.shared.paths.contains("/3/movie/102/rating"),"Queued save reaches its remote endpoint without manual retry")
        print("\(count) concurrency checks passed.")
    }
}
