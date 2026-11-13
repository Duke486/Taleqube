import Foundation
import CoreGraphics
import ImageIO

@main struct LanguageChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value:Bool,_ label:String) { precondition(value,label); count += 1; print("PASS: \(label)") }
        func solidArtwork(_ r:CGFloat,_ g:CGFloat,_ b:CGFloat) -> Data {
            let context = CGContext(data:nil,width:8,height:8,bitsPerComponent:8,bytesPerRow:32,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red:r,green:g,blue:b,alpha:1)); context.fill(CGRect(x:0,y:0,width:8,height:8))
            let data = NSMutableData(); let destination = CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil)!
            CGImageDestinationAddImage(destination,context.makeImage()!,nil); precondition(CGImageDestinationFinalize(destination)); return data as Data
        }
        let redPalette = ArtworkPalette.extract(solidArtwork(0.8,0.2,0.15))
        check(redPalette.red > redPalette.green * 2,"Artwork sampling retains dominant chromatic hue")
        check(ArtworkPalette.extract(Data()) == .neutral,"Invalid artwork uses neutral palette")
        let whitePalette = ArtworkPalette.extract(solidArtwork(1,1,1))
        let blackPalette = ArtworkPalette.extract(solidArtwork(0,0,0))
        check(!whitePalette.usesDarkAppearance(systemDark:false) && blackPalette.usesDarkAppearance(systemDark:false),"White and black artwork retain their brightness")
        check(whitePalette.theme(systemDark:true).dark,"System dark overrides even a white source image")
        check(blackPalette.seed.chroma < 0.001 && whitePalette.seed.chroma < 0.001,"Monochrome artwork has no invented hue")
        check(blackPalette.theme(systemDark:false).accent.chroma < 0.001,"Monochrome controls also retain neutral color")
        let darkBlue = ArtworkPalette.extract(solidArtwork(0.02,0.07,0.19))
        check(darkBlue.theme(systemDark:false).dark && darkBlue.blue > darkBlue.red,"Dark colored artwork retains hue and activates dark detail")
        let brightYellow = ArtworkPalette.extract(solidArtwork(1,0.9,0.2))
        check(!brightYellow.theme(systemDark:false).dark,"Bright artwork keeps a light detail in light system mode")
        let lightTheme = brightYellow.theme(systemDark:false)
        check(lightTheme.canvas.chroma > 0.005 && lightTheme.canvas.chroma < 0.055,"Light artwork surfaces retain a pale tint")
        check(lightTheme.canvas.luminance > 0.8,"Light artwork canvas stays close to white")
        check(darkBlue.theme(systemDark:false).canvas.chroma > 0.035,"Dark canvas retains visible artwork color")
        // A small vivid highlight cannot erase the mood of a predominantly black image.
        func splitArtwork() -> Data {
            let context = CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:256,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red:0.01,green:0.01,blue:0.01,alpha:1)); context.fill(CGRect(x:0,y:0,width:64,height:64))
            context.setFillColor(CGColor(red:1,green:0.8,blue:0.1,alpha:1)); context.fill(CGRect(x:0,y:0,width:12,height:64))
            let data = NSMutableData(); let destination = CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil)!
            CGImageDestinationAddImage(destination,context.makeImage()!,nil); precondition(CGImageDestinationFinalize(destination)); return data as Data
        }
        let dramatic = ArtworkPalette.extract(splitArtwork())
        check(dramatic.darkCoverage > 0.75 && dramatic.theme(systemDark:false).dark,"Image-wide dark coverage survives colorful highlights")
        check(ArtworkPalette.extract(splitArtwork()) == dramatic,"Quantization and theme seed selection are deterministic")
        var verifiedThemes = 0
        for r in stride(from:0.0,through:1.0,by:0.2) {
            for g in stride(from:0.0,through:1.0,by:0.2) {
                for b in stride(from:0.0,through:1.0,by:0.2) {
                    let seed = ArtworkPalette(red:r,green:g,blue:b)
                    for dark in [false,true] {
                        for increased in [false,true] {
                            let theme = ArtworkTheme(palette:seed,dark:dark,increasedContrast:increased)
                            let surfaces = [theme.canvas,theme.bottom,theme.card,theme.raised]
                            for surface in surfaces {
                                precondition(theme.primary.contrast(with:surface) >= 7)
                                precondition(theme.secondary.contrast(with:surface) >= (increased ? 7 : 4.5))
                                precondition(theme.accent.contrast(with:surface) >= (increased ? 7 : 4.5))
                                precondition(surface.red >= 0 && surface.green >= 0 && surface.blue >= 0 && max(surface.red,surface.green,surface.blue) <= 1)
                                if dark { precondition(surface.luminance < 0.08) }
                            }
                            // Interpolated gradient stops must also remain readable.
                            for step in 0...10 {
                                let t = Double(step)/10
                                let color = ArtworkColor(red:theme.canvas.red*(1-t)+theme.bottom.red*t,green:theme.canvas.green*(1-t)+theme.bottom.green*t,blue:theme.canvas.blue*(1-t)+theme.bottom.blue*t)
                                precondition(theme.secondary.contrast(with:color) >= (increased ? 7 : 4.5))
                            }
                            verifiedThemes += 1
                        }
                    }
                }
            }
        }
        check(verifiedThemes == 864,"864 themes meet text contrast, sRGB gamut and dark-surface constraints, including gradient interiors")
        if CommandLine.arguments.contains("--artwork-only") {
            print("Artwork checks passed: \(count); generated themes: \(verifiedThemes)")
            return
        }
        check(MediaLanguage.isChinese("这是中文简介，包含 English 名字。"),"Chinese mixed prose skips translation")
        check(!MediaLanguage.isChinese("進撃の巨人"),"Kana titles are translated")
        check(!MediaLanguage.isChinese("Attack on Titan"),"English titles are translated")
        check(MediaLanguage.terms([" Test ","test","","原名"]) == ["Test","原名"],"Aliases trim and deduplicate")
        check(MediaLanguage.terms([String(repeating:"a",count:121)]).isEmpty,"Oversized aliases are rejected")
        check(EpisodeWindow.range(offset:0,viewport:440,count:1000) == 0..<5,"Episode strip initially loads visible cards and three ahead")
        let middleWindow = EpisodeWindow.range(offset:234*500,viewport:440,count:1000)
        check(middleWindow == 497..<505,"Episode strip prefetch stays bounded in a thousand-episode season")
        check(EpisodeWindow.range(offset:234*999,viewport:440,count:1000) == 996..<1000,"Episode prefetch clamps at season end")
        check(EpisodeWindow.range(offset:-120,viewport:440,count:1000) == 0..<5,"Scroll bounce cannot request negative episode indices")
        check(EpisodeWindow.range(offset:0,viewport:0,count:1000).isEmpty && EpisodeWindow.range(offset:0,viewport:440,count:0).isEmpty,"Unmeasured and empty episode strips issue no prefetch")
        check(EpisodeWindow.range(offset:234*500,viewport:1100,count:1000).count <= 11,"Wide iPad strip still preloads only a bounded neighborhood")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LanguageFixtureProtocol.self]
        let diagnosticsDirectory = FileManager.default.temporaryDirectory.appending(path:UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:diagnosticsDirectory) }
        let api = CatalogAPI(session:URLSession(configuration:configuration),credential:{ _ in "fixture" },diagnostics:DiagnosticLog(directory:diagnosticsDirectory))
        let seededWork = Work(source:.anilist,remoteID:"seed",kind:.tv,title:"Seeded search")
        let seeded = try await MediaSearch(api:api).search(.anilist,kind:.tv,query:"Seeded search",expand:false,seed:[seededWork])
        check(seeded.works.map(\.id) == [seededWork.id] && LanguageFixtureProtocol.requests.isEmpty,"Seeded first-page search reuses results without a duplicate network request")

        let ai = Intelligence(api:api,credential:{ _ in "fixture" })
        let search = MediaSearch(api:api,intelligence:ai)
        var updates: [Int] = []
        let found = try await search.search(.trakt,kind:.tv,query:"进击的巨人") { updates.append($0.works.count) }
        check(found.works.map(\.remoteID) == ["1","2","3"],"Native and foreign queries merge in stable order")
        check(updates.first == 1 && updates.last == 3,"Initial results appear before alias search completes")
        check(found.terms.contains("Attack on Titan") && found.terms.contains("進撃の巨人"),"Both English and original names are searched")
        check(!found.terms.contains("Invented Title"),"Ungrounded model aliases are discarded")
        _ = try await search.search(.trakt,kind:.tv,query:"进击的巨人")
        check(LanguageFixtureProtocol.requests.filter { $0.url?.path == "/v1/tools/search" }.count == 1,"Repeated query reuses researched aliases")
        let searchBody = LanguageFixtureProtocol.bodies.first { $0["query"] != nil }!
        check(searchBody["count"] as? Int == 5 && searchBody["need_content"] as? Bool == false,"Web evidence is bounded without fetching full pages")
        check((searchBody["query"] as? String ?? "").unicodeScalars.count <= 128,"Search respects DeepSeek query length")
        let resolution = try await search.resolve("进击的巨人",kind:.tv)
        check(resolution.chineseTitle == "进击的巨人" && resolution.sources.count == 1,"Chinese lookup retains cited source")
        let lookupCalls = LanguageFixtureProtocol.bodies.filter { ($0["messages"] as? [[String:Any]])?.first?["content"] as? String != nil }
        check(lookupCalls.count == 4,"Each of two distinct name resolutions uses exactly two model calls")
        let researchOrder = LanguageFixtureProtocol.requests.filter { $0.url?.host == "api.deepseek.com" }.map { $0.url!.path }
        check(researchOrder == Array(repeating:["/chat/completions","/v1/tools/search","/chat/completions"],count:2).flatMap { $0 },"Model plans before DS search and answers after evidence")
        let metadataWork = Work(source:.tmdb,remoteID:"99",kind:.tv,title:"no-web",original:"Attack on Titan Season 2",overview:"Second season metadata",year:"2017")
        let fallback = try await search.resolve(metadataWork,refresh:true)
        check(fallback.chineseTitle == "进击的巨人" && fallback.sources.isEmpty && fallback.origin == "AI 已知译名","Empty search still resolves from model knowledge without fake sources")
        let modelBodies = LanguageFixtureProtocol.bodies.filter { $0["messages"] != nil }
        let lastMessages = modelBodies.suffix(2).map { $0["messages"] as! [[String:Any]] }
        check(lastMessages.allSatisfy { ($0.last?["content"] as? String ?? "").contains("Second season metadata") && ($0.last?["content"] as? String ?? "").contains("2017") },"Both model calls receive native title, synopsis, kind and year")
        check((lastMessages.last!.last?["content"] as? String ?? "").contains("empty"),"Empty evidence is explicitly passed to final model")
        let roundStart = LanguageFixtureProtocol.bodies.count
        var richWork = Work(source:.tmdb,remoteID:"333",kind:.tv,title:"three-round",original:"Native title",overview:String(repeating:"故事",count:1000) + "结尾线索",year:"2024")
        richWork.episodeCount = 12; richWork.tmdbID = 333; richWork.format = "TV"
        let thirdRound = try await search.resolve(richWork,refresh:true)
        let roundBodies = Array(LanguageFixtureProtocol.bodies.dropFirst(roundStart))
        let roundModels = roundBodies.filter { $0["messages"] != nil }.map { $0["messages"] as! [[String:Any]] }
        check(thirdRound.chineseTitle == "进击的巨人" && roundBodies.filter { $0["query"] != nil }.count == 3,"Unresolved Chinese title can use three searches and resolve on the last")
        check(roundModels.count == 6 && roundModels.suffix(2).allSatisfy { ($0.first?["content"] as? String ?? "").contains("LAST search opportunity") },"Both final search planner and answer receive last-opportunity instruction")
        let finalInput = try JSONSerialization.jsonObject(with:Data((roundModels.last!.last!["content"] as! String).utf8)) as! [String:Any]
        let supplied = finalInput["work"] as! [String:Any]
        check(supplied["episodes"] as? String == "12" && supplied["tmdbID"] as? String == "333" && (supplied["overview"] as? String ?? "").contains("结尾线索"),"Chinese lookup receives richer metadata and synopsis beyond the old limit")
        check(finalInput["final"] as? Bool == true && (finalInput["already_searched"] as? [String])?.count == 2 && (finalInput["evidence"] as? [[String:String]])?.count == 3,"Final lookup includes prior queries and all three rounds of evidence")
        let translatedFallback = try await search.resolve("no-web translation",kind:.movie,refresh:true)
        check(translatedFallback.chineseTitle == "月下旅途" && translatedFallback.origin == "AI 翻译","Translation fallback remains usable and records its origin")
        let outage = try await search.resolve("search-down",kind:.tv,refresh:true)
        check(outage.chineseTitle == "进击的巨人" && outage.sources.isEmpty,"Search API outage still reaches the final model with metadata")
        let snippetOnly = try await search.resolve("snippet-only",kind:.tv,refresh:true)
        check(snippetOnly.aliases.contains("Attack on Titan") && snippetOnly.chineseTitle == "进击的巨人","Empty summary still includes snippets for the answer")
        check(Intelligence.jsonObject("```json\n{\"query\":\"test\"}\n```")?["query"] as? String == "test","Fenced JSON is parsed")
        check(Intelligence.jsonObject("{\"query\":") == nil && Intelligence.jsonObject("[]") == nil,"Truncated JSON and non-object responses are rejected")
        check(Intelligence.nameSearchQuery(["query":" \n "],work:metadataWork).contains("Attack on Titan"),"Blank model search query falls back to native metadata")
        check(Intelligence.nameSearchQuery(["query":String(repeating:"名",count:200)],work:metadataWork).unicodeScalars.count == 128,"Oversized model queries are bounded")
        let missingBasis = Intelligence.parseNames(["chinese_title":"進擊的巨人"],evidence:[],rows:[])
        check(missingBasis.chineseTitle == "进击的巨人" && missingBasis.sources.isEmpty,"Usable title survives missing provenance field")
        check(MediaLanguage.isLocalizedTitle("EVA") && !MediaLanguage.isLocalizedTitle("Eva") && !MediaLanguage.isLocalizedTitle("123") && !MediaLanguage.isLocalizedTitle(""),"Localized titles accept pure uppercase letters without accepting lowercase or empty titles")
        let uppercaseName = Intelligence.parseNames(["chinese_title":"EVA","basis":"knowledge","names":[]],evidence:[],rows:[])
        check(uppercaseName.chineseTitle == "EVA" && !MediaLanguage.isChinese("EVA"),"Uppercase title is accepted without changing prose language detection")
        for name in ["NEW GAME！","NEW GAME!","NEW GAME!!","86 EIGHTY-SIX","ＮＥＷ ＧＡＭＥ！","HUNTER×HUNTER"] {
            check(MediaLanguage.isLocalizedTitle(name),"Uppercase localized title accepts typography: \(name)")
            check(Intelligence.parseNames(["chinese_title":name,"basis":"knowledge","names":[]],evidence:[],rows:[]).chineseTitle == name,"Name parser preserves typography: \(name)")
        }
        check(!MediaLanguage.isLocalizedTitle("New Game!") && !MediaLanguage.isLocalizedTitle("！！ 123") && !MediaLanguage.isLocalizedTitle("NEW\nGAME"),"Uppercase exception rejects lowercase, letterless and multiline titles")
        let invalidNames = Intelligence.parseNames(["chinese_title":"進擊的巨人","basis":"web","title_evidence":[true,-1,8],"names":[["name":"fake","evidence":true]]],evidence:[["title":"進擊的巨人","summary":""]],rows:[["url":"javascript:bad"]])
        check(invalidNames.chineseTitle == "进击的巨人" && invalidNames.sources.isEmpty && invalidNames.aliases.isEmpty && invalidNames.origin != "联网查证","Invalid indices, booleans and unsafe citations cannot claim web provenance")
        var associationDraft = TrackingRecord(work:metadataWork)
        check(!associationDraft.isPlatformEnabled(.anilist),"Unmatched platforms default to disabled")
        associationDraft.confirmedProgress.insert("anilist")
        associationDraft.mappedProgress["anilist"] = [1,2,3]
        associationDraft.associate(Work(source:.anilist,remoteID:"1",kind:.tv,title:"Match"))
        check(associationDraft.isPlatformEnabled(.anilist) && !associationDraft.confirmedProgress.contains("anilist") && associationDraft.mappedProgress["anilist"] == nil,"A successful match enables platform and clears old numbering confirmation")
        check(associationDraft.isPlatformEnabled(.anilist),"A matched platform stays enabled")
        var work = Work(source:.anilist,remoteID:"10",kind:.tv,title:"Foreign title",original:"Original",overview:"Do not send this long synopsis in a title batch",year:"2020")
        let many = (1...15).map { number in Work(source:.anilist,remoteID:String(number),kind:.tv,title:"Foreign \(number)",overview:"SECRET_OVERVIEW") }
        let titles = try await ai.translateTitles(many)
        check(titles.count == 12,"Title requests are limited to twelve items")
        let titleBody = LanguageFixtureProtocol.capture { _,body in
            ((body["messages"] as? [[String:Any]])?.last?["content"] as? String)?.contains("Foreign 1") == true
        }!.body
        let messages = titleBody["messages"] as! [[String:Any]]
        let titlePayload = messages.last?["content"] as! String
        check(!titlePayload.contains("SECRET_OVERVIEW"),"Title batches exclude descriptions")
        check(titleBody["max_tokens"] as? Int == 1600,"Title generation has a token cap")
        let requestCount = LanguageFixtureProtocol.requests.count
        _ = try await ai.translateTitles([Work(source:.anilist,remoteID:"zh",kind:.tv,title:"中文作品")])
        _ = try await ai.translateOverview("这是已经存在的中文简介。")
        check(LanguageFixtureProtocol.requests.count == requestCount,"Chinese titles and synopses make no AI request")
        let directory = FileManager.default.temporaryDirectory.appending(path:UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        var store = TrackingStore(directory:directory,api:api,intelligence:ai,mediaSearch:search)
        store.setTitle("自定义译名",for:work)
        check(store.display(work).title == "自定义译名","Manual title is used in the shared display path")
        let restored = TrackingStore(directory:directory,api:api,intelligence:ai,mediaSearch:search)
        check(restored.display(work).title == "自定义译名","Title survives store restart without TTL")
        work.overview = "Changed synopsis"
        check(restored.display(work).title == "自定义译名","Synopsis changes do not invalidate the title")
        work.title = "Changed title"
        check(restored.display(work).title == "Changed title","Changed source title invalidates translation")
        work.title = "Foreign title"; work.original = "Changed original"
        check(restored.display(work).title == "Foreign title","Changed native title invalidates translation")
        let originalWork = Work(source:.anilist,remoteID:"10",kind:.tv,title:"Foreign title",original:"Original",overview:"English synopsis")
        try await restored.translateDescription(originalWork)
        let afterOverview = LanguageFixtureProtocol.requests.count
        try await restored.translateDescription(originalWork)
        check(LanguageFixtureProtocol.requests.count == afterOverview,"Synopsis translation is reused for unchanged text")
        var changedSynopsis = originalWork; changedSynopsis.overview = "A different synopsis"
        check(restored.overviewTranslation(changedSynopsis) == nil,"Changed synopsis invalidates its own translation")
        // Continue editing through the instance that most recently committed.
        store = restored
        let fresh = Work(source:.anilist,remoteID:"100",kind:.tv,title:"Another title")
        store.queueTitle(fresh)
        store.setTitle("手动优先",for:fresh)
        try await Task.sleep(for:.milliseconds(700))
        check(store.display(fresh).title == "手动优先","Pending background batch preserves manual edits")
        let lookup = Work(source:.anilist,remoteID:"200",kind:.tv,title:"进击的巨人")
        try await store.researchTitle(lookup)
        check(store.titleTranslation(lookup)?.origin == "联网查证","One-click researched title persists with provenance")
        let uppercaseWork = Work(source:.anilist,remoteID:"202",kind:.tv,title:"uppercase-title")
        try await store.researchTitle(uppercaseWork)
        check(store.display(uppercaseWork).title == "EVA" && store.titleTranslation(uppercaseWork)?.origin == "AI 已知译名","Uppercase researched Chinese name saves and displays unchanged")
        let newGame = Work(source:.anilist,remoteID:"203",kind:.tv,title:"NEW GAME！",overview:"A young woman joins a game development studio.")
        let beforeNewGame = LanguageFixtureProtocol.requests.filter { $0.url?.path == "/v1/tools/search" }.count
        try await store.researchTitle(newGame)
        check(store.display(newGame).title == "NEW GAME！" && store.titleTranslation(newGame)?.origin == "AI 已知译名","NEW GAME title is saved unchanged as a successful Chinese name lookup")
        check(LanguageFixtureProtocol.requests.filter { $0.url?.path == "/v1/tools/search" }.count == beforeNewGame + 1,"Recognized NEW GAME title completes after one search instead of three")
        let unresolved = Work(source:.anilist,remoteID:"201",kind:.tv,title:"unresolved-title")
        try await store.researchTitle(unresolved)
        check(store.titleTranslation(unresolved)?.origin == "AI 翻译" && store.display(unresolved).title.contains("译名"),"Empty researched title falls back to title translation")
        let removable = TrackingRecord(work:Work(source:.trakt,remoteID:"9810",kind:.movie,title:"Remove me"),score:8)
        store.library["trakt"] = [removable]
        try await store.deleteSourceRecord(removable)
        check(store.library["trakt"]?.isEmpty == true,"Source deletion removes cached platform entry")
        let removalPaths = Set(LanguageFixtureProtocol.requests.compactMap { $0.url?.path }.filter { $0.hasSuffix("/remove") })
        check(["watchlist","collection","ratings","history"].allSatisfy { removalPaths.contains("/sync/\($0)/remove") },"Source deletion clears lists, rating and watch history")
        let artwork = CatalogAPI.tmdbArtwork(["backdrop_path":"/a.jpg","images":["backdrops":[["file_path":"/a.jpg"],["file_path":"/b.jpg"]]],"seasons":[["season_number":2,"name":"第二季"],["season_number":1,"name":"第一季"]]])
        check(artwork.images.count == 2,"Backdrop gallery removes duplicate hero images")
        check(artwork.seasons.map(\.number) == [1,2],"Seasons are ordered numerically")
        let episodes = CatalogAPI.tmdbEpisodes(["episodes":[["episode_number":2,"name":"第二集","still_path":"/still.jpg"],["episode_number":1,"name":"第一集"]]])
        check(episodes.map(\.number) == [1,2] && episodes[0].image.isEmpty,"Missing episode images retain episode metadata")
        check(episodes[1].image == "https://image.tmdb.org/t/p/w780/still.jpg","Episode image uses TMDB still URL")
        let exact = try await api.tmdbDetails(id:123,kind:.tv)
        check(exact.remoteID == "123" && exact.source == .tmdb,"Trakt TMDB ID resolves directly without name matching")
        let legacy = try JSONDecoder().decode(Backup.self,from:Data("{\"version\":1,\"records\":{},\"deliveries\":[],\"translations\":{},\"handledHistory\":[]}".utf8))
        check(legacy.localizations == nil,"Old library backup remains decodable")
        let roundtrip = try JSONDecoder().decode(Backup.self,from:JSONEncoder().encode(store.backup))
        check(roundtrip.localizations?.titles[fresh.id]?.text == "手动优先","Backup includes durable translations")
        check(MediaLanguage.plainText("<p>A<br>B&nbsp;&amp;C</p><script>alert(1)</script>") == "A\nB &C","HTML tags and active content are removed while line breaks remain")
        check(MediaLanguage.plainText("&lt;b&gt;&#x4E2D;&#25991;&lt;/b&gt;") == "中文","Encoded tags and numeric entities become plain Chinese")
        check(MediaLanguage.plainText("<style>.a{color:red}</style><b>标题</b>") == "标题","CSS and markup never leak into titles")
        let association = TrackingRecord(work:Work(source:.trakt,remoteID:"501",kind:.tv,title:"Source"),score:9,progress:12,status:"已完成",links:["tmdb":Work(source:.tmdb,remoteID:"701",kind:.tv,title:"主条目")])
        store.saveAssociations(association)
        check(store.backup.records.isEmpty && store.backup.associations?[association.id] != nil,"Saving an association never admits a work to the library")
        var confirmedAssociation = association
        confirmedAssociation.confirmedProgress.insert("tmdb")
        store.saveAssociations(confirmedAssociation)
        let associationReloaded = TrackingStore(directory:directory,api:api,intelligence:ai,mediaSearch:search).record(association.work)
        check(associationReloaded.confirmedProgress.contains("tmdb"),"Association progress confirmation persists immediately across store reload")
        let matchingDirectory = directory.appending(path:"automatic-matching")
        let matchingStore = TrackingStore(directory:matchingDirectory,api:api,intelligence:ai,mediaSearch:search)
        let matchingWork = Work(source:.tmdb,remoteID:"808",kind:.tv,title:"Match series")
        var matchingRecord = TrackingRecord(work:matchingWork,score:8,progress:4)
        matchingRecord.prepareUnits()
        let unitID = matchingRecord.viewingUnits![0].id
        let aniTarget = Work(source:.anilist,remoteID:"809",kind:.tv,title:"Match season")
        let otherTarget = Work(source:.anilist,remoteID:"810",kind:.tv,title:"Manual choice")
        check(matchingRecord.associate(aniTarget,unitID:unitID,onlyIfMissing:true),"Automatic match directly attaches a season target")
        check(matchingRecord.isPlatformEnabled(.anilist),"Successful automatic match enables its platform")
        check(!matchingRecord.associate(otherTarget,unitID:unitID,onlyIfMissing:true) && matchingRecord.platformLinks?.first?.target.id == aniTarget.id,"Automatic match cannot overwrite an existing manual association")
        matchingStore.saveAssociations(matchingRecord)
        let unopened = TrackingStore(directory:matchingDirectory,api:api,intelligence:ai,mediaSearch:search)
        check(unopened.backup.records.isEmpty && unopened.record(matchingWork).platformLinks?.first?.target.id == aniTarget.id,"Season association persists without importing the work")
        try matchingStore.admit(matchingRecord,using:matchingWork)
        var edit = matchingStore.record(matchingWork)
        edit.score = 2; edit.viewingUnits?[0].score = 3; edit.viewingUnits?[0].markThrough(20)
        let malTarget = Work(source:.mal,remoteID:"811",kind:.tv,title:"Match season")
        check(edit.associate(malTarget,unitID:unitID,onlyIfMissing:true),"Another platform can attach to the same season")
        matchingStore.saveAssociations(edit)
        let persistedMatch = matchingStore.record(matchingWork)
        check(persistedMatch.score == 8 && persistedMatch.viewingUnits?.first?.progress == 4 && persistedMatch.viewingUnits?.first?.score == nil,"Association persistence does not commit unfinished scores or progress")
        check(persistedMatch.platformLinks?.contains(where:{ $0.id == malTarget.id }) == true,"New platform association persists immediately")
        let failedDelivery = Delivery(record:matchingRecord,target:aniTarget,state:"连接失败")
        matchingStore.backup.deliveries = [failedDelivery,Delivery(record:matchingRecord,target:malTarget),Delivery(record:matchingRecord,target:aniTarget,state:"已同步")]
        check(matchingStore.deliveryErrorCount == 1,"Sync badge counts failures but not waiting or successful jobs")
        matchingStore.clearDeliveryErrorCount()
        check(matchingStore.deliveryErrorCount == 0 && matchingStore.backup.deliveries.count == 3,"Clearing error badge retains history and retryable jobs")
        let badgeReload = TrackingStore(directory:matchingDirectory,api:api,intelligence:ai,mediaSearch:search)
        check(badgeReload.deliveryErrorCount == 0,"Cleared sync error count survives restart")
        matchingStore.backup.deliveries[0].state = "服务不可用"
        check(matchingStore.deliveryErrorCount == 1,"A changed failure is counted again")
        matchingStore.backup.deliveries.append(Delivery(record:matchingRecord,target:aniTarget,state:"连接失败"))
        check(matchingStore.deliveryErrorCount == 2,"A new failed delivery is counted after clearing old errors")
        let dateDirectory = directory.appending(path:"library-dates")
        try FileManager.default.createDirectory(at:dateDirectory,withIntermediateDirectories:true)
        let oldDate = Date(timeIntervalSince1970:1000)
        let knownDate = Date(timeIntervalSince1970:2000)
        var datedRecord = TrackingRecord(work:matchingWork,addedAt:oldDate,modifiedAt:knownDate)
        let dateStore = TrackingStore(directory:dateDirectory,api:api,intelligence:ai,mediaSearch:search)
        var partialDates = Backup(); datedRecord.modifiedAt = nil; partialDates.records[datedRecord.id] = datedRecord
        check(partialDates.fillMissingLibraryDates(now:knownDate) && partialDates.records[datedRecord.id]?.addedAt == oldDate && partialDates.records[datedRecord.id]?.modifiedAt == knownDate,"Migration fills only missing fields")
        check(!partialDates.fillMissingLibraryDates(now:Date()),"Date migration is idempotent")
        dateStore.backup.records[datedRecord.id] = partialDates.records[datedRecord.id]
        dateStore.updateStatus([datedRecord.id],to:"已暂停")
        check(dateStore.record(matchingWork).addedAt == oldDate && (dateStore.record(matchingWork).modifiedAt ?? .distantPast) > knownDate,"Status edits update modified date and preserve admission date")
        let afterStatus = dateStore.record(matchingWork).modifiedAt
        dateStore.updateStatus([datedRecord.id],to:"已暂停")
        check(dateStore.record(matchingWork).modifiedAt == afterStatus,"Unchanged bulk status does not move modified date")
        var freshRecord = datedRecord; freshRecord.addedAt = knownDate; freshRecord.modifiedAt = oldDate
        datedRecord.modifiedAt = knownDate
        check(LibrarySort.added.precedes(freshRecord,datedRecord,titleA:"Z",titleB:"A"),"Admission sorting puts newest first")
        check(LibrarySort.modified.precedes(datedRecord,freshRecord,titleA:"Z",titleB:"A"),"Modification sorting puts newest first independently")
        let novelBook = Work(source:.anilist,remoteID:"9001",kind:.manga,title:"Novel",format:"NOVEL")
        let comicBook = Work(source:.anilist,remoteID:"9002",kind:.manga,title:"Comic",format:"MANGA")
        check(BookFilter.all.includes(novelBook) && BookFilter.all.includes(comicBook),"All books includes novels and manga")
        check(BookFilter.novel.includes(novelBook) && !BookFilter.novel.includes(comicBook) && BookFilter.manga.includes(comicBook) && !BookFilter.manga.includes(novelBook),"Book filters distinguish light novels from manga")
        var migrationCredentials:[String:String] = [:]
        let exportedDates = try dateStore.exportApplicationData(credentials:[:])
        let dateTarget = TrackingStore(directory:directory.appending(path:"date-import"),api:api,intelligence:ai,mediaSearch:search)
        try dateTarget.importApplicationData(exportedDates,readCredential:{ migrationCredentials[$0] ?? "" },writeCredential:{ migrationCredentials.merge($0) { _,new in new } })
        check(dateTarget.record(matchingWork).addedAt == dateStore.record(matchingWork).addedAt && dateTarget.record(matchingWork).modifiedAt == dateStore.record(matchingWork).modifiedAt,"Full backup restores both dates without resetting them")
        dateStore.backup.records[matchingWork.id]?.modifiedAt = oldDate
        let beforeSave = Date()
        check(await dateStore.save(dateStore.record(matchingWork)),"Library record save succeeds with date metadata")
        check(dateStore.record(matchingWork).addedAt == oldDate && (dateStore.record(matchingWork).modifiedAt ?? .distantPast) >= beforeSave,"Saving progress preserves admission date and advances modified date")
        dateStore.backup.records[matchingWork.id]?.modifiedAt = oldDate
        let beforeRename = Date()
        dateStore.setTitle("修改后的标题",for:matchingWork)
        check((dateStore.record(matchingWork).modifiedAt ?? .distantPast) >= beforeRename,"Editing a title updates library modification date")
        let beforeImport = LanguageFixtureProtocol.trackingWriteCount
        try store.admit(association,using:association.links["tmdb"]!)
        let canonicalID = "tmdb:tv:701"
        check(store.backup.records[canonicalID]?.score == 9 && store.backup.records[association.id] == nil,"TV import uses TMDB identity and preserves user data")
        check(LanguageFixtureProtocol.trackingWriteCount == beforeImport,"Import never writes progress or ratings to remote platforms")
        var duplicate = association; duplicate.score = 2
        try store.admit(duplicate,using:association.links["tmdb"]!)
        check(store.backup.records.count == 1 && store.backup.records[canonicalID]?.score == 9,"Duplicate import preserves existing library ratings")
        var secondSeason = association; secondSeason.work.remoteID = "502"; secondSeason.progress = 6
        try store.admit(secondSeason,using:association.links["tmdb"]!)
        check(store.backup.records[canonicalID]?.sourceRecords?.count == 2 && store.libraryRecord(for:secondSeason.work)?.id == canonicalID,"Multiple source seasons retain individual progress under one canonical title")
        var legacyRecord = association; legacyRecord.work.remoteID = "503"; legacyRecord.links = [:]; legacyRecord.libraryException = "旧版记录，待确认主条目"
        store.backup.records[legacyRecord.id] = legacyRecord
        legacyRecord.links["tmdb"] = Work(source:.tmdb,remoteID:"702",kind:.tv,title:"迁移主条目")
        store.saveAssociations(legacyRecord)
        check(store.backup.records[legacyRecord.id] == nil && store.backup.records["tmdb:tv:702"]?.libraryException == nil,"Associating a legacy exception immediately migrates its canonical identity")
        let manga = TrackingRecord(work:Work(source:.bangumi,remoteID:"1",kind:.manga,title:"漫画"))
        let mangaPrimary = Work(source:.anilist,remoteID:"8",kind:.manga,title:"漫画原名")
        check(try LibraryIdentity.canonical(manga,using:mangaPrimary).work.source == .anilist,"Manga is canonicalized to AniList")
        do { _ = try LibraryIdentity.canonical(manga,using:manga.work); preconditionFailure("Accepted noncanonical manga") } catch { check(true,"Noncanonical import requires explicit exception") }
        check(try LibraryIdentity.canonical(manga,using:manga.work,exception:true).libraryException != nil,"Explicit catalog exception is retained")
        var unlinked = association; unlinked.links = [:]; unlinked.work.remoteID = "999"
        check(await store.save(unlinked) == false && store.backup.records[unlinked.id] == nil,"Progress save cannot silently create a noncanonical library record")
        let movies = try await api.anilistPage(kind:.movie,query:"",page:1,filters:AniListFilters(year:2024,season:"FALL",sort:.score))
        let movieVariables = LanguageFixtureProtocol.capture { _,body in
            (body["query"] as? String)?.contains("query Browse(") == true && (body["variables"] as? [String:Any])?["year"] as? Int == 2024
        }!.body["variables"] as! [String:Any]
        check(movieVariables["format"] as? String == "MOVIE","Movie discovery filters MOVIE on the server")
        check(movieVariables["year"] as? Int == 2024 && movieVariables["season"] as? String == "FALL","Year and season reach the AniList query")
        check(movies.works.count == 4 && movies.hasNext,"Movie page retains all movies and pagination state")
        _ = try await api.anilistPage(kind:.tv,query:"",page:2,filters:AniListFilters(format:"OVA"))
        let tvVariables = LanguageFixtureProtocol.capture { _,body in
            (body["query"] as? String)?.contains("query Browse(") == true && (body["variables"] as? [String:Any])?["page"] as? Int == 2
        }!.body["variables"] as! [String:Any]
        check(tvVariables["format"] as? String == "OVA" && tvVariables["excludedFormat"] as? String == "MOVIE","TV-format filtering excludes movies at the API")
        _ = try await api.search(.bangumi,kind:.movie,query:"测试")
        let bangumiSearch = LanguageFixtureProtocol.capture { request,_ in request.url?.path == "/v0/search/subjects" }!
        let bangumiRequest = bangumiSearch.request
        let bangumiBody = bangumiSearch.body
        check(bangumiRequest.value(forHTTPHeaderField:"Authorization") == "Bearer fixture","Bangumi search sends configured account token")
        check((bangumiBody["filter"] as? [String:Any])?["type"] as? [Int] == [2,6],"Bangumi movie matching includes animation and live action")
        check(try await api.bangumiViewer(token:"fixture") == "测试账号","Bangumi token login verifies the actual account")
        let bgmWork = Work(source:.bangumi,remoteID:"5",kind:.tv,title:"Animation")
        try await api.save(TrackingRecord(work:bgmWork,score:8).ratingPayload(),to:bgmWork)
        let bgmWrite = LanguageFixtureProtocol.capture { request,_ in
            request.url?.path == "/v0/users/-/collections/5" && request.httpMethod == "POST"
        }!.body
        check(bgmWrite["ep_status"] == nil && bgmWrite["vol_status"] == nil && bgmWrite["rate"] as? Int == 8,"Bangumi TV writes omit book-only progress fields")
        let log = DiagnosticLog(directory:directory.appending(path:"logs"))
        let now = Date(timeIntervalSince1970:2_000_000_000)
        log.record(component:"old",message:"old",now:now.addingTimeInterval(-90000))
        log.record(component:"recent",message:"recent",url:URL(string:"https://example.com/path?token=private"),now:now.addingTimeInterval(-60))
        let firstExport = log.prepareExport(now:now)
        check(firstExport.events.count == 1 && firstExport.events[0].path == "/path","Diagnostics export only last 24h and excludes query parameters")
        check(log.prepareExport(now:now).events.count == 1,"Preparing or cancelling export never advances watermark")
        log.record("warning",component:"during",message:"during export",now:now.addingTimeInterval(1))
        log.markExported(firstExport)
        let nextExport = log.prepareExport(now:now.addingTimeInterval(2))
        check(nextExport.events.count == 1 && nextExport.events.first?.component == "during","Events during export are retained for the next export")
        log.markExported(nextExport)
        check(log.prepareExport(now:now.addingTimeInterval(3)).events.isEmpty,"Successful export excludes already exported events")
        let redacted = DiagnosticLog.redacted("Authorization: Bearer secret-value api_key=private-key access_token=hidden")
        check(!redacted.contains("secret-value") && !redacted.contains("private-key") && !redacted.contains("hidden"),"Diagnostic redaction removes bearer and key values")
        _ = try await api.anilistPage(kind:.tv,query:"",page:1,filters:AniListFilters(year:2025,season:"SUMMER",allAnime:true,minimumScore:80,country:"JP",sort:.favourites))
        let animeVariables = LanguageFixtureProtocol.capture { _,body in
            (body["query"] as? String)?.contains("query Browse(") == true && (body["variables"] as? [String:Any])?["year"] as? Int == 2025
        }!.body["variables"] as! [String:Any]
        check(animeVariables["excludedFormat"] == nil && animeVariables["minimumScore"] as? Int == 79 && animeVariables["country"] as? String == "JP","Anime discovery includes movies and applies minimum score and origin on the server")
        _ = try await api.tmdbPage(kind:.movie,query:"",page:2,filters:TMDBFilters(year:2024,genre:16,language:"ja",minimumScore:7,minimumVotes:100,maximumRuntime:120,sort:"vote_average.desc"))
        let tmdbRequest = LanguageFixtureProtocol.requests.last { $0.url?.host == "api.themoviedb.org" && $0.url?.path == "/3/discover/movie" }!
        let tmdbParams = Dictionary(uniqueKeysWithValues:URLComponents(url:tmdbRequest.url!,resolvingAgainstBaseURL:false)!.queryItems!.map { ($0.name,$0.value ?? "") })
        check(tmdbRequest.url?.path == "/3/discover/movie" && tmdbParams["page"] == "2" && tmdbParams["primary_release_year"] == "2024","TMDB discovery uses paginated server discovery and movie year")
        check(tmdbParams["with_genres"] == "16" && tmdbParams["vote_average.gte"] == "7" && tmdbParams["with_runtime.lte"] == "120" && tmdbParams["sort_by"] == "vote_average.desc","TMDB genre, score, runtime and sorting reach the API")
        _ = try await api.tmdbPage(kind:.tv,query:"a&b",page:1,filters:TMDBFilters(year:2022))
        let searchParams = URLComponents(url:LanguageFixtureProtocol.requests.last { $0.url?.path == "/3/search/tv" }!.url!,resolvingAgainstBaseURL:false)!.queryItems!
        check(searchParams.contains { $0.name == "query" && $0.value == "a&b" } && searchParams.contains { $0.name == "first_air_date_year" && $0.value == "2022" },"TMDB search escapes query and uses TV search year")
        _ = try await api.search(.bangumi,kind:.tv,query:"",provider:ProviderFilters(sort:"score",year:2024,season:"FALL",genre:"科幻",minimumScore:8,animationOnly:true))
        let filteredBGM = LanguageFixtureProtocol.capture { request,body in
            request.url?.path == "/v0/search/subjects" && body["sort"] as? String == "score"
        }!.body["filter"] as! [String:Any]
        check(filteredBGM["type"] as? [Int] == [2] && filteredBGM["air_date"] as? [String] == [">=2024-10-01","<2025-01-01"] && filteredBGM["rating"] as? [String] == [">=8"],"Bangumi anime uses animated subjects, quarter boundaries and score filters")
        let suite = "Taleqube-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set(256,forKey:"artwork.cacheLimitMB"); defaults.set("client",forKey:"anilist.clientID")
        try store.admit(manga,using:mangaPrimary)
        store.backup.deliveries = [Delivery(record:store.backup.records[canonicalID]!,target:association.work)]
        store.recent = [(association.work,4,2,"event")]
        store.recommendations["anilist"] = [association.work]
        let exported = try store.exportApplicationData(credentials:["tmdb.token":"archive-token"],defaults:defaults)
        let importDirectory = directory.appending(path:"full-restore")
        let target = TrackingStore(directory:importDirectory,api:api,intelligence:ai,mediaSearch:search)
        var credentials:[String:String] = [:]
        defaults.set(128,forKey:"artwork.cacheLimitMB")
        try target.importApplicationData(exported,defaults:defaults,readCredential:{ credentials[$0] ?? "" },writeCredential:{ credentials.merge($0) { _,new in new } })
        check(target.backup.records.count == store.backup.records.count && target.backup.deliveries.count == 1 && target.recent.first?.1 == 4,"Complete restore preserves library, pending deliveries and viewing history")
        check(credentials["tmdb.token"] == "archive-token" && defaults.integer(forKey:"artwork.cacheLimitMB") == 256 && defaults.string(forKey:"anilist.clientID") == "client","Complete restore recovers account configuration and preferences")
        check(target.backup.associations?.count == store.backup.associations?.count && target.localizations.titles == store.localizations.titles,"Complete restore retains associations and manual translations")
        let today = Date(timeIntervalSince1970:2_000_000_000)
        check(target.dailyPicks(manga:false,now:today) == target.dailyPicks(manga:false,now:today.addingTimeInterval(1)),"Daily picks stay stable within a day")
        check(target.dailyPicks(manga:true,now:today).allSatisfy { $0.kind == .manga } && target.dailyPicks(manga:false,now:today).allSatisfy { $0.kind != .manga },"Daily picks keep manga and video separate")
        target.updateStatus([canonicalID],to:"已暂停")
        check(target.backup.records[canonicalID]?.status == "已暂停","Bulk status updates persist locally")
        let beforeDelete = LanguageFixtureProtocol.trackingWriteCount
        target.selected = association.work
        target.deleteRecords([canonicalID])
        let reloaded = TrackingStore(directory:importDirectory,api:api,intelligence:ai,mediaSearch:search)
        check(reloaded.recent.first?.1 == 4 && reloaded.recommendations["anilist"]?.count == 1,"Restored history and recommendations survive restarting the app")
        check(reloaded.backup.records[canonicalID] == nil && reloaded.backup.deliveries.isEmpty && target.selected == nil,"Deletion persists and removes pending deliveries and linked selection")
        check(LanguageFixtureProtocol.trackingWriteCount == beforeDelete && target.backup.records[mangaPrimary.id] != nil,"Deleting selected video never writes to platforms or deletes manga")
        do {
            try target.importApplicationData(Data("{\"version\":99}".utf8),defaults:defaults,readCredential:{ migrationCredentials[$0] ?? "" },writeCredential:{ migrationCredentials.merge($0) { _,new in new } })
            preconditionFailure("Accepted unsupported archive")
        } catch { check(target.backup.records[mangaPrimary.id] != nil,"Unsupported backups leave existing library intact") }
        let editingDirectory = FileManager.default.temporaryDirectory.appending(path:UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:editingDirectory) }
        let editorConfiguration = URLSessionConfiguration.ephemeral
        editorConfiguration.protocolClasses = [LanguageFixtureProtocol.self]
        editorConfiguration.httpAdditionalHeaders = ["X-Taleqube-Test-Scope":"local-editor"]
        let editorAPI = CatalogAPI(session:URLSession(configuration:editorConfiguration),credential:{ _ in "fixture" },diagnostics:DiagnosticLog(directory:diagnosticsDirectory))
        let editor = TrackingStore(directory:editingDirectory,api:editorAPI,intelligence:ai,mediaSearch:search)
        func editorRequests() -> Int {
            LanguageFixtureProtocol.requests.filter { $0.value(forHTTPHeaderField:"X-Taleqube-Test-Scope") == "local-editor" }.count
        }
        let primary = Work(source:.tmdb,remoteID:"9801",kind:.tv,title:"编辑测试")
        let remoteEntry = Work(source:.anilist,remoteID:"9802",kind:.tv,title:"第二季")
        var editing = TrackingRecord(work:primary,score:8,progress:5,season:2,links:["anilist":remoteEntry])
        let beforeLocalSave = editorRequests()
        check(await editor.save(editing,synchronize:false),"Explicit local save succeeds")
        check(editorRequests() == beforeLocalSave && editor.backup.deliveries.isEmpty,"Local save makes no remote request or delivery")
        check(try editing.payload(for:remoteEntry).progressDisabled.contains("anilist"),"Unconfirmed numbering cannot write remote progress")
        editing.confirmedProgress.insert("anilist")
        do { _ = try editing.payload(for:remoteEntry); preconditionFailure("Accepted missing season mapping") }
        catch { check(true,"TV synchronization requires explicit season mapping") }
        editing.progressMappings = ["anilist":ProgressMapping(localSeason:2,targetSeason:1,episodeOffset:12)]
        let mapped = try editing.payload(for:remoteEntry)
        check(mapped.progress == 17 && mapped.season == 1,"Target season and episode offset are applied")
        editing.season = 3
        do { _ = try editing.payload(for:remoteEntry); preconditionFailure("Accepted stale mapping") }
        catch { check(true,"Changing local season invalidates target mapping") }
        editing.season = 2
        editor.backup.deliveries = [Delivery(record:editing,target:remoteEntry)]
        let associated = editing
        editor.saveAssociations(associated)
        check(!editor.backup.deliveries.isEmpty,"Saving an associated platform retains queued writes")
        editor.backup.deliveries = [Delivery(record:editing,target:remoteEntry)]
        var replaced = editing; replaced.links["anilist"] = Work(source:.anilist,remoteID:"9999",kind:.tv,title:"其他")
        editor.saveAssociations(replaced)
        check(editor.backup.deliveries.isEmpty,"Replacing association removes writes to old target")
        var other = editing; other.work.remoteID = "9803"
        editor.backup.deliveries = [Delivery(record:other,target:remoteEntry)]
        editing.prepareUnits()
        editing.platformLinks = [PlatformAssociation(target:remoteEntry,scope:.season,season:2)]
        check(await editor.save(editing,synchronize:true),"Explicit platform synchronization succeeds")
        check(editor.backup.deliveries.contains { $0.record.id == other.id && $0.state == "等待同步" },"Saving one work does not retry another work")
        editor.deleteRecords([primary.id])
        var cleared = editing; cleared.score = nil; cleared.scoreCleared = true
        cleared.progressDisabled = Set(Catalog.allCases.map(\.rawValue))
        try await api.save(cleared,to:remoteEntry)
        let aniListClear = LanguageFixtureProtocol.capture { _,body in
            (body["query"] as? String)?.contains("SaveMediaListEntry") == true &&
            (body["variables"] as? [String:Any])?["id"] as? Int == Int(remoteEntry.remoteID)
        }
        check((aniListClear?.body["variables"] as? [String:Any])?["score"] as? Int == 0,"AniList rating clear sends zero scoreRaw")
        let bangumiEntry = Work(source:.bangumi,remoteID:"9804",kind:.tv,title:"测试")
        try await api.save(cleared,to:bangumiEntry)
        check(LanguageFixtureProtocol.capture { request,_ in request.url?.path == "/v0/users/-/collections/9804" && request.httpMethod == "POST" }?.body["rate"] as? Int == 0,"Bangumi rating clear sends zero rate")
        let traktEntry = Work(source:.trakt,remoteID:"9805",kind:.tv,title:"测试")
        try await api.save(cleared,to:traktEntry)
        check(LanguageFixtureProtocol.requests.last { $0.url?.host == "api.trakt.tv" && $0.httpMethod == "POST" }?.url?.path == "/sync/ratings/remove","Trakt clear uses ratings removal endpoint")
        let malEntry = Work(source:.mal,remoteID:"9806",kind:.tv,title:"测试")
        try await api.save(cleared,to:malEntry)
        check(String(data:LanguageFixtureProtocol.capture { request,_ in request.url?.path == "/v2/anime/9806/my_list_status" && request.httpMethod == "PATCH" }?.raw ?? Data(),encoding:.utf8)?.contains("score=0") == true,"MAL clear sends zero score")
        let truncatedTitles = try await ai.translateTitles([Work(source:.anilist,remoteID:"7001",kind:.tv,title:"truncate A"),Work(source:.anilist,remoteID:"7002",kind:.tv,title:"truncate B")])
        check(truncatedTitles.count == 2,"Truncated title batches split into smaller requests without losing titles")
        let beforeExact = LanguageFixtureProtocol.requests.filter { $0.url?.path == "/v1/tools/search" }.count
        let exactExpansion = try await search.search(.trakt,kind:.tv,query:"Work 1")
        check(exactExpansion.terms.contains("Attack on Titan") && LanguageFixtureProtocol.requests.filter { $0.url?.path == "/v1/tools/search" }.count == beforeExact + 1,"Exact title hits retain AI plus web alias expansion")
        let emptyPlatform = try await search.search(.bangumi,kind:.tv,query:"Empty platform query")
        check(emptyPlatform.works.isEmpty && emptyPlatform.terms.contains("Attack on Titan"),"Platform and association search retry evidenced aliases after empty results")
        let discovery = TrackingStore(directory:diagnosticsDirectory.appending(path:"discovery"),api:api,intelligence:ai,mediaSearch:search)
        discovery.kind = .tv; discovery.searchSource = .trakt; discovery.query = "Discovery fallback"
        await discovery.search()
        check(discovery.searchTerms.contains("Attack on Titan") && !discovery.results.isEmpty,"Discovery entry point uses the shared researched alias pipeline")
        print("\(count) language and artwork checks passed.")
    }
}

final class LanguageFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var log: [URLRequest] = []
    private static var jsonLog: [[String:Any]] = []
    private static var rawLog: [Data] = []
    static var rawBodies: [Data] { lock.lock(); defer { lock.unlock() }; return rawLog }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return log }
    static var bodies: [[String:Any]] { lock.lock(); defer { lock.unlock() }; return jsonLog }
    static var trackingWriteCount:Int {
        lock.lock(); defer { lock.unlock() }
        return log.indices.filter { index in
            let request = log[index], path = request.url?.path ?? ""
            guard !["GET","HEAD"].contains(request.httpMethod ?? "GET") else { return false }
            switch request.url?.host {
            case "graphql.anilist.co":
                let body = (try? JSONSerialization.jsonObject(with:rawLog[index])) as? [String:Any]
                return (body?["query"] as? String)?.contains("mutation") == true
            case "api.trakt.tv": return path.hasPrefix("/sync/")
            case "api.bgm.tv": return path.hasPrefix("/v0/users/") && path.contains("/collections/")
            case "api.myanimelist.net": return path.hasSuffix("/my_list_status")
            case "api.themoviedb.org": return path.hasSuffix("/rating")
            default: return false
            }
        }.count
    }
    // Background metadata and delivery requests share this fixture. Keep each
    // request paired with its body instead of assuming the global last call is ours.
    static func capture(_ predicate:(URLRequest,[String:Any]) -> Bool) -> (request:URLRequest,body:[String:Any],raw:Data)? {
        lock.lock(); defer { lock.unlock() }
        for index in log.indices.reversed() {
            let raw = rawLog[index]
            let body = (try? JSONSerialization.jsonObject(with:raw)) as? [String:Any] ?? [:]
            if predicate(log[index],body) { return (log[index],body,raw) }
        }
        return nil
    }
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable { let n = stream.read(&bytes,maxLength:bytes.count); if n <= 0 { break }; body.append(bytes,count:n) }
        }
        let json = (try? JSONSerialization.jsonObject(with:body)) as? [String:Any] ?? [:]
        Self.lock.lock(); Self.log.append(request); Self.rawLog.append(body); if !json.isEmpty { Self.jsonLog.append(json) }; Self.lock.unlock()
        let url = request.url!
        var value: Any = [:]
        if url.path == "/v1/tools/search", (json["query"] as? String ?? "").contains("search-down") {
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:503,httpVersion:nil,headerFields:[:])!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:Data("{\"error\":{\"message\":\"Search unavailable\"}}".utf8))
            client?.urlProtocolDidFinishLoading(self); return
        }
        switch url.path {
        case "/v1/tools/search":
            if (json["query"] as? String ?? "").contains("three-round") { value = ["results":[["title":"进击的巨人","url":"https://example.com/" + (json["query"] as! String).addingPercentEncoding(withAllowedCharacters:.urlPathAllowed)!,"summary":"进击的巨人"]]] }
            else if (json["query"] as? String ?? "").contains("no-web") { value = ["results":[]] }
            else if (json["query"] as? String ?? "").contains("snippet-only") { value = ["results":[["title":"進擊的巨人","url":"https://example.com/media","summary":"","snippet":"進擊的巨人，原名進撃の巨人，英文名Attack on Titan。"]]] }
            else { value = ["results":[["title":"进击的巨人 / Attack on Titan / 進撃の巨人","url":"https://example.com/media","summary":"进击的巨人，原名進撃の巨人，英文名Attack on Titan。"]]] }
        case "/chat/completions":
            let messages = json["messages"] as! [[String:Any]]
            let system = messages[0]["content"] as! String
            let payload = messages[1]["content"] as! String
            var object: [String:Any] = [:]
            var finish = "stop"
            if system.contains("NAME_SEARCH_PLAN") {
                let input = try! JSONSerialization.jsonObject(with:Data(payload.utf8)) as! [String:Any]
                let work = input["work"] as! [String:Any]
                object = ["query":"\(work["title"] as! String) 中文名" + (work["title"] as? String == "three-round" ? " \(input["round"] as? Int ?? 1)" : "")]
            } else if system.contains("NAME_SEARCH_ANSWER") {
                let input = try! JSONSerialization.jsonObject(with:Data(payload.utf8)) as! [String:Any]
                let empty = input["search_state"] as? String != "results"
                let work = input["work"] as! [String:Any]
                let translated = (work["title"] as? String ?? "").contains("translation")
                object = empty ? ["names":[["name":"Attack on Titan","evidence":NSNull()]],"chinese_title":translated ? "月下旅途" : "进击的巨人","basis":translated ? "translation" : "knowledge","title_evidence":[]] : ["names":[["name":"Attack on Titan","evidence":0],["name":"進撃の巨人","evidence":0],["name":"进击的巨人","evidence":0],["name":"Invented Title","evidence":0]],"chinese_title":"进击的巨人","basis":"web","title_evidence":[0]]
                if work["title"] as? String == "three-round", input["final"] as? Bool != true { object = ["chinese_title":NSNull(),"basis":"unknown","names":[]] }
                if work["title"] as? String == "NEW GAME！" { object = ["chinese_title":"NEW GAME！","basis":"knowledge","names":[]] }
                if work["title"] as? String == "uppercase-title" { object = ["chinese_title":"EVA","basis":"knowledge","names":[]] }
                if work["title"] as? String == "unresolved-title" { object = ["chinese_title":NSNull(),"basis":"unknown","names":[]] }
            } else if system.contains("Translate these media titles") {
                let items = try! JSONSerialization.jsonObject(with:Data(payload.utf8)) as! [[String:String]]
                if items.count > 1 && items.contains(where: { $0["title"]?.hasPrefix("truncate") == true }) { finish = "length" }
                object = ["titles":items.map { ["id":$0["id"]!,"title":"译名" + $0["title"]!] }]
            } else { object = ["overview":"中文简介"] }
            value = ["choices":[["finish_reason":finish,"message":["content":String(decoding:try! JSONSerialization.data(withJSONObject:object),as:UTF8.self)]]]]
        case "/search/show":
            let term = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "query" }?.value
            let ids = term == "Attack on Titan" ? [1,2] : term == "進撃の巨人" ? [2,3] : [1]
            value = ids.map { ["show":["title":"Work \($0)","ids":["trakt":$0]]] }
        case "", "/":
            let variables = json["variables"] as? [String:Any] ?? [:]
            value = ["data":["Page":["pageInfo":["hasNextPage":(variables["page"] as? Int ?? 1) == 1],"media":(1...4).map { ["id":$0,"title":["native":"作品\($0)"],"type":"ANIME","format":"MOVIE"] as [String:Any] }]]]
        case "/v0/search/subjects": value = ["data":[]]
        case "/v0/me": value = ["nickname":"测试账号"]
        case "/v0/users/-/collections/5", "/v0/users/-/collections/9804", "/sync/ratings/remove", "/sync/watchlist/remove", "/sync/collection/remove", "/sync/history/remove", "/v2/anime/9806/my_list_status", "/v2/anime/811/my_list_status": value = [:]
        case "/3/discover/movie", "/3/search/tv": value = ["results":[],"total_pages":3]
        case "/3/tv/9801/rating", "/3/tv/808/rating": value = ["success":true]
        case "/3/tv/123": value = ["id":123,"name":"中文剧名","original_name":"Original","first_air_date":"2020-01-01"]
        default: preconditionFailure("Unexpected fixture route: \(url.path)")
        }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:[:])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:value))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
