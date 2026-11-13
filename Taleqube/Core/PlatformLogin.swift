import Foundation
import AuthenticationServices
import UIKit

@MainActor final class PlatformLogin:NSObject,ASWebAuthenticationPresentationContextProviding {
    static let shared = PlatformLogin()
    private var session:ASWebAuthenticationSession?
    private var anchor:UIWindow?
    private var active = false
    private var accountCheckTask:Task<Void,Never>?
    func credentialsDidChange() {
        accountCheckTask?.cancel()
        accountCheckTask = Task {
            do { try await Task.sleep(for:.seconds(1)) } catch { return }
            await checkAccounts()
        }
    }
    private var refreshTasks:[Catalog:Task<Void,Error>] = [:]
    func checkAccounts(force:Bool = false) async {
        for source in Catalog.allCases {
            guard !Task.isCancelled else { return }
            await AccountHealth.shared.check(source,force:force,recover:{ try await self.refresh($0) })
        }
    }
    func presentationAnchor(for session:ASWebAuthenticationSession) -> ASPresentationAnchor { anchor! }
    struct DeviceCode:Decodable {
        let device_code:String
        let user_code:String
        let verification_url:URL
        let expires_in:Int
        let interval:Int
    }
    func loginTrakt(onCode:(DeviceCode) -> Void) async throws {
        guard !active else { throw APIError.message("请先完成当前登录") }
        let client = try Credentials.readChecked("trakt.clientID").trimmingCharacters(in:.whitespacesAndNewlines)
        guard !client.isEmpty else { throw APIError.message("请先保存 Client ID") }
        active = true
        defer { active = false }
        let (data,response) = try await deviceRequest("code",body:["client_id":client])
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw APIError.message("无法获取 Trakt 授权码（\(response.statusCode)）") }
        let code = try JSONDecoder().decode(DeviceCode.self,from:data)
        guard code.expires_in > 0, code.interval > 0,
              code.verification_url.scheme == "https" else { throw APIError.message("Trakt 返回的授权信息无效") }
        onCode(code)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by:.seconds(code.expires_in))
        var interval = code.interval
        while clock.now < deadline {
            try await clock.sleep(until:min(clock.now.advanced(by:.seconds(interval)),deadline))
            guard clock.now < deadline else { break }
            let (data,response) = try await deviceRequest("token",body:["client_id":client,"code":code.device_code])
            try Task.checkCancellation()
            switch response.statusCode {
            case 200:
                let tokens = try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
                try store(tokens,platform:.trakt)
                return
            case 400: continue // Authorization is still pending.
            case 429: interval += 5
            case 404: throw APIError.message("Trakt 授权码无效，请重新登录")
            case 409: throw APIError.message("Trakt 授权码已使用，请重新登录")
            case 410: throw APIError.message("Trakt 授权码已过期，请重新登录")
            case 418: throw APIError.message("Trakt 授权已被拒绝")
            default: throw APIError.message("Trakt 授权失败（\(response.statusCode)）")
            }
        }
        throw APIError.message("Trakt 授权码已过期，请重新登录")
    }
    private func deviceRequest(_ endpoint:String,body:[String:String]) async throws -> (Data,HTTPURLResponse) {
        var request = URLRequest(url:URL(string:"https://api.trakt.tv/oauth/device/\(endpoint)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue("Taleqube/2.0 (personal tracking client)",forHTTPHeaderField:"User-Agent")
        request.httpBody = try JSONEncoder().encode(body)
        let (data,response) = try await URLSession.shared.data(for:request)
        guard let http = response as? HTTPURLResponse else { throw APIError.message("没有收到 Trakt 响应") }
        return (data,http)
    }
    func login(_ platform:Catalog) async throws {
        guard !active else { throw APIError.message("请先完成当前登录") }
        guard platform == .mal else { throw APIError.message("请使用 Trakt 设备码登录") }
        let client = try Credentials.readChecked("\(platform.rawValue).clientID")
        guard !client.isEmpty else { throw APIError.message("请先保存 Client ID") }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where:{ $0.activationState == .foregroundActive })?.windows.first(where:\.isKeyWindow) else { throw APIError.message("请回到 App 后登录") }
        anchor = window; active = true
        defer { active = false; session = nil; anchor = nil }
        let verifier = UUID().uuidString.replacingOccurrences(of:"-",with:"") + UUID().uuidString.replacingOccurrences(of:"-",with:"")
        let state = UUID().uuidString
        let redirect = "anishelf://oauth/\(platform.rawValue)"
        let challenge = verifier
        var url = URLComponents(string:"https://myanimelist.net/v1/oauth2/authorize")!
        url.queryItems = [URLQueryItem(name:"response_type",value:"code"),URLQueryItem(name:"client_id",value:client),URLQueryItem(name:"redirect_uri",value:redirect),URLQueryItem(name:"state",value:state),URLQueryItem(name:"code_challenge",value:challenge),URLQueryItem(name:"code_challenge_method",value:"plain")]
        let callback:URL = try await withCheckedThrowingContinuation { continuation in
            let s = ASWebAuthenticationSession(url:url.url!,callbackURLScheme:"anishelf") { address,error in
                if let address { continuation.resume(returning:address) } else { continuation.resume(throwing:error ?? APIError.message("登录未完成")) }
            }
            session = s; s.presentationContextProvider = self
            if !s.start() { continuation.resume(throwing:APIError.message("无法打开登录窗口")) }
        }
        guard callback.scheme == "anishelf", callback.host == "oauth", callback.path == "/\(platform.rawValue)" else { throw APIError.message("登录回调不匹配") }
        let params = URLComponents(url:callback,resolvingAgainstBaseURL:false)?.queryItems ?? []
        guard params.first(where:{ $0.name == "state" })?.value == state, let code = params.first(where:{ $0.name == "code" })?.value else { throw APIError.message("登录验证失败，请重试") }
        let form = ["grant_type":"authorization_code","client_id":client,"redirect_uri":redirect,"code":code,"code_verifier":verifier]
        let tokenURL = "https://myanimelist.net/v1/oauth2/token"
        let response = try await CatalogAPI.shared.request(tokenURL,method:"POST",form:form) as? [String:Any] ?? [:]
        try store(response,platform:platform)
    }
    func store(_ response:[String:Any],platform:Catalog,ifUnchanged expected:[String:String]? = nil) throws {
        guard let token = response["access_token"] as? String, !token.isEmpty else { throw APIError.message("登录未返回令牌") }
        let refreshName = "\(platform.rawValue).refresh"
        let values = ["\(platform.rawValue).token":token,
                      refreshName:response["refresh_token"] as? String ?? expected?[refreshName] ?? ""]
        if let expected { _ = try Credentials.writeValues(values,ifUnchanged:expected) }
        else { try Credentials.writeValues(values) }
    }
    func refresh(_ platform:Catalog) async throws {
        if let task = refreshTasks[platform] { return try await task.value }
        let task = Task { try await self.refreshCredentials(platform) }
        refreshTasks[platform] = task
        defer { refreshTasks[platform] = nil }
        try await task.value
    }
    private func refreshCredentials(_ platform:Catalog) async throws {
        let names = ["\(platform.rawValue).token","\(platform.rawValue).refresh","\(platform.rawValue).clientID"]
        let previous = try Credentials.readValuesChecked(names)
        let refresh = previous["\(platform.rawValue).refresh"] ?? ""
        guard !refresh.isEmpty else { throw APIError.message("请重新登录 \(platform.title)") }
        let response = try await CatalogAPI.shared.request(platform == .trakt ? "https://auth.trakt.tv/oauth/token" : "https://myanimelist.net/v1/oauth2/token",method:"POST",form:["grant_type":"refresh_token","client_id":previous["\(platform.rawValue).clientID"] ?? "","refresh_token":refresh]) as? [String:Any] ?? [:]
        try store(response,platform:platform,ifUnchanged:previous)
    }
}

extension PlatformLogin {
    func loginTMDB() async throws {
        guard !active else { throw APIError.message("请先完成当前登录") }
        let token = Credentials.read("tmdb.token")
        guard !token.isEmpty else { throw APIError.message("请先保存 TMDB API Read Access Token") }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where:{ $0.activationState == .foregroundActive })?.windows.first(where:\.isKeyWindow) else { throw APIError.message("请回到 App 后登录") }
        anchor = window; active = true
        defer { active = false; session = nil; anchor = nil }
        let headers = ["Authorization":"Bearer \(token)"]
        let response = try await CatalogAPI.shared.request("https://api.themoviedb.org/3/authentication/token/new",headers:headers) as? [String:Any] ?? [:]
        guard response["success"] as? Bool == true, let requestToken = response["request_token"] as? String else { throw APIError.message("TMDB 未返回授权令牌") }
        let state = UUID().uuidString
        var authorization = URLComponents(string:"https://www.themoviedb.org/authenticate/\(requestToken)")!
        authorization.queryItems = [URLQueryItem(name:"redirect_to",value:"anishelf://oauth/tmdb?state=\(state)")]
        let callback:URL = try await withCheckedThrowingContinuation { continuation in
            let authentication = ASWebAuthenticationSession(url:authorization.url!,callbackURLScheme:"anishelf") { address,error in
                if let address { continuation.resume(returning:address) }
                else { continuation.resume(throwing:error ?? APIError.message("TMDB 登录未完成")) }
            }
            session = authentication; authentication.presentationContextProvider = self
            if !authentication.start() { continuation.resume(throwing:APIError.message("无法打开 TMDB 登录窗口")) }
        }
        let query = URLComponents(url:callback,resolvingAgainstBaseURL:false)?.queryItems ?? []
        guard callback.scheme == "anishelf", callback.host == "oauth", callback.path == "/tmdb",
              query.first(where:{ $0.name == "state" })?.value == state else { throw APIError.message("TMDB 登录回调验证失败") }
        let result = try await CatalogAPI.shared.request("https://api.themoviedb.org/3/authentication/session/new",method:"POST",headers:headers,body:["request_token":requestToken]) as? [String:Any] ?? [:]
        guard result["success"] as? Bool == true, let id = result["session_id"] as? String, !id.isEmpty else { throw APIError.message("TMDB 未授权账号访问") }
        try Credentials.write("tmdb.session",id)
    }
    func logoutTMDB() async throws {
        let id = Credentials.read("tmdb.session")
        if !id.isEmpty {
            _ = try await CatalogAPI.shared.request("https://api.themoviedb.org/3/authentication/session",method:"DELETE",headers:["Authorization":"Bearer \(Credentials.read("tmdb.token"))"],body:["session_id":id])
        }
        try Credentials.write("tmdb.session","")
    }
}
