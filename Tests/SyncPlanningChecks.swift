import Foundation
final class SyncProbeProtocol: URLProtocol, @unchecked Sendable {
    static var writes = 0
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.writes += 1
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data("{\"data\":{}}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct SyncPlanningChecks {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SyncProbeProtocol.self]
        let api = CatalogAPI(session:URLSession(configuration:config),credential:{ _ in "fixture" },
                             diagnostics:DiagnosticLog(directory:directory.appendingPathComponent("logs")))
        let store = TrackingStore(directory:directory,api:api)
        let primary = Work(source:.tmdb,remoteID:"1",kind:.tv,title:"Split")
        func association(_ id:String,_ offset:Int) -> PlatformAssociation {
            let target = Work(source:.anilist,remoteID:id,kind:.tv,title:id)
            return PlatformAssociation(target:target,scope:.season,mapping:ContentMapping(tmdbID:"1",confirmed:true,seasons:[1],coverage:"partial",episodes:(1...2).map { EpisodeCorrespondence(platformEpisodes:[$0],tmdbEpisodes:[EpisodeAddress(season:1,number:$0+offset)]) },platformEpisodeCount:2,complete:true))
        }
        func settle() async throws {
            for _ in 0..<200 {
                try await Task.sleep(for:.milliseconds(10))
                if !store.backup.deliveries.contains(where:{ ["等待同步","同步中"].contains($0.state) }) { return }
            }
            preconditionFailure("sync did not settle")
        }
        var initial = TrackingRecord(work:primary)
        initial.prepareUnits(); initial.viewingUnits?[0].lastEpisode = 4
        initial.platformLinks = [association("2",0),association("3",2)]
        var edited = initial; edited.viewingUnits?[0].markThrough(3)
        let saved = await store.saveProgressChanges(edited,from:initial); precondition(saved)
        try await settle()
        precondition(SyncProbeProtocol.writes == 4,"First submission writes progress and status for both parts")
        let previous = store.libraryRecord(for:primary)!
        edited = previous; edited.viewingUnits?[0].markThrough(4)
        let savedAgain = await store.saveProgressChanges(edited,from:previous); precondition(savedAgain)
        try await settle()
        precondition(SyncProbeProtocol.writes == 6,"Only changed second part writes")
        await store.synchronizeSaved(primary); try await settle()
        precondition(SyncProbeProtocol.writes == 6,"Unchanged submission is silent")
        var linked = store.libraryRecord(for:primary)!; linked.platformLinks?.append(association("4",2))
        let linkedOK = await store.saveAssociationsAsync(linked); precondition(linkedOK)
        try await settle()
        precondition(SyncProbeProtocol.writes == 8,"New association automatically receives committed progress")
        await store.synchronizeSaved(primary,force:true); try await settle()
        precondition(SyncProbeProtocol.writes == 14,"Force resends all associated progress and status")
        print("5 synchronization planning checks passed")
    }
}
