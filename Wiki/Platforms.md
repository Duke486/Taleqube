# 接入各平台

入口位于应用设置的账号区域。手动填写配置后先保存，再执行登录或账号检查。密钥在本机 Keychain 保存；加入加密 S3 资料库后，账号凭据也随资料库加密同步。

## TMDB：影视主资料与评分

1. 登录 [TMDB API 设置](https://www.themoviedb.org/settings/api)，申请自己的 API 凭据。
2. 复制 **API Read Access Token**，填写到 Taleqube 的 TMDB 配置并保存。此处使用读取令牌，不是网页密码。
3. 如需把整部个人评分提交给 TMDB，在应用中完成 TMDB 网页授权，生成用户会话。
4. 返回应用执行账号检查；资料读取令牌与评分会话分别验证。

影视身份、季集坐标与图片以 TMDB 为基础。只有读取令牌时可读取资料；整部评分写入和删除需要用户会话。[官方认证说明](https://developer.themoviedb.org/docs/authentication-application)

## Trakt：片单、历史与观看进度

1. 在 [Trakt API 应用页](https://trakt.tv/oauth/applications) 注册自己的应用，Redirect URI 填 `http://localhost`。
2. 把 **Client ID** 填入 Taleqube 并保存。
3. 点击登录，按应用显示的设备码与验证网址前往网页授权。
4. 授权完成后回到 Taleqube，登录窗口会自动结束。
5. 刷新独立的 Trakt 页面与首页最近观看，读取片单及观看记录。

Trakt 使用设备授权流程，不需要把网页密码或 Client Secret 填入 Taleqube。访问令牌失效时，应用会尝试使用刷新令牌恢复。[官方 API 文档](https://trakt.docs.apiary.io/)

## AniList：动漫与书籍资料、片单与同步

1. 打开 [AniList 开发者设置](https://anilist.co/settings/developer)，创建应用。
2. Redirect URL 填 `anishelf://oauth`。
3. 在 Taleqube 填写 **Client ID** 并保存，再点击 AniList 登录。
4. 在网页允许授权后返回应用。也可以在手动配置中填入自己的 Access Token。

Taleqube 使用面向客户端的隐式授权，应用中无需填写 Client Secret。书籍以 AniList 为主条目，平台片单有独立入口。[官方认证说明](https://docs.anilist.co/guide/auth/)

## Bangumi：访问令牌登录

1. 在 [Bangumi Access Token 页面](https://next.bgm.tv/demo/access-token) 登录并创建自己的个人访问令牌。
2. 在 Taleqube 的 Bangumi 配置中填入 Access Token，保存。
3. 点击账号验证登录按钮，确认账号状态。

Bangumi 提供作品关联、评分和进度同步；剧集进度按真实章节对应提交。令牌到期后在应用中替换并保存。[官方 API 文档](https://bangumi.github.io/api/)

## MyAnimeList：OAuth 与片单

1. 在 [MyAnimeList API 配置页](https://myanimelist.net/apiconfig) 注册自己的客户端。
2. 回调地址填写 `anishelf://oauth/mal`，使用适合本机应用的客户端配置。
3. 将 Client ID 填入 Taleqube，保存后点击登录。
4. 在网页完成授权并返回应用。应用使用 PKCE 处理授权，不要求填写 Client Secret。

[官方 API 文档](https://myanimelist.net/apiconfig/references/api/v2)

## 账号异常时

先保存表单，再执行立即检查。未登录、登录失效与暂时无法验证是不同状态：网络暂时失败时保留凭据，可在网络恢复后重试。更换账号或令牌后再次检查，避免混用不同账号的片单。

反馈问题时提供平台、操作步骤和脱敏后的错误日志，勿提交 Token、API Key、S3 密钥、加入码或完整备份。
