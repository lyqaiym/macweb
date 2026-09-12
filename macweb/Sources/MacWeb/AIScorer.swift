import Foundation
import PDFKit

struct AIScorer {
    struct Result {
        let report: String
        let savedPath: String
    }

    enum ScoreError: LocalizedError {
        case missingAPIKey
        case resumeNotSet
        case resumeNotFound(String)
        case resumeParseFailed(String)
        case http(Int, String)
        case emptyReport

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "未设置 DEEPSEEK_API_KEY，请点工具栏「API Key」设置"
            case .resumeNotSet:
                return "尚未选择简历文件"
            case .resumeNotFound(let p):
                return "简历文件不存在：\(p)"
            case .resumeParseFailed(let p):
                return "无法解析简历（可能不是可提取文本的 PDF）：\(p)"
            case .http(let code, let body):
                return "DeepSeek 接口返回 \(code)：\(body)"
            case .emptyReport:
                return "模型未返回有效报告"
            }
        }
    }

    // 个人工具用固定配置，可按需修改；简历路径通过「选简历」写入 .env 的 RESUME_PATH
    static let envPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // MacWeb
        .deletingLastPathComponent() // Sources
        .deletingLastPathComponent() // macweb
        .appendingPathComponent(".env")
        .path
    static let outputDir = NSString(string: "~/Documents/macweb_scores").expandingTildeInPath
    static let model = "deepseek-v4-pro"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    static let systemPrompt = """
    你是一名资深技术招聘专家（HR + 技术面评委）。
    你的任务是：根据提供的岗位要求和候选人简历，严格按岗位要求给简历打分。

    评分维度与权重（总分 100）：
    - 硬性条件（学历、工作年限、必备技能、地点/语言等硬门槛）：25 分
    - 技术栈匹配度（岗位要求的技术与简历实际使用深度）：25 分
    - 项目 / 业务经验匹配度（规模、复杂度、行业相关性、个人贡献）：25 分
    - 职业发展与稳定性（跳槽频率、职级成长、空窗期）：15 分
    - 加分项（开源、专利、论文、竞赛、影响力、岗位额外偏好）：10 分

    打分要求：
    - 每个维度给出得分、满分、评分依据，依据必须引用简历中的原文或具体事实，禁止臆造经历。
    - 简历中没有体现的能力按"未体现"处理并扣分，不要假设候选人具备。
    - 若命中硬性条件不达标（如学历、年限、必备技能缺失），在报告开头明确标注"硬性条件不满足项"。
    - 总分为各维度得分之和；根据总分给出结论：
      85 以上强烈推荐面试 / 70-84 推荐面试 / 60-69 待定 / 60 以下不推荐。

    报告结构（markdown）：
    1. 候选人概览（姓名或脱敏标识、当前岗位、总年限、学历）
    2. 总分与结论
    3. 各维度评分表（维度 / 得分 / 满分 / 评分依据）
    4. 匹配亮点
    5. 风险与差距
    6. 建议面试追问问题（3-5 条，针对简历中含糊或高风险的点）
    """

    static func score(jd: String) async throws -> Result {
        do {
            log("开始打分，JD 长度 \(jd.count) 字符")
            let env = loadEnv()
            log("env 文件：\(envPath)，解析到 \(env.keys.count) 个变量")
            guard let apiKey = env["DEEPSEEK_API_KEY"], !apiKey.isEmpty else {
                log("缺少 DEEPSEEK_API_KEY")
                throw ScoreError.missingAPIKey
            }
            let baseURL = env["DEEPSEEK_BASE_URL"] ?? "https://api.deepseek.com"
            guard let resumePathValue = env["RESUME_PATH"], !resumePathValue.isEmpty else {
                log("RESUME_PATH 未设置")
                throw ScoreError.resumeNotSet
            }
            let resumePath = expandTilde(resumePathValue)
            log("baseURL=\(baseURL)，model=\(model)，apiKey=\(mask(apiKey))")
            log("简历路径=\(resumePath)")
            let resume = try readResume(at: resumePath)
            log("简历解析完成，\(resume.count) 字符")
            let report = try await requestReport(apiKey: apiKey, baseURL: baseURL, jd: jd, resume: resume)
            log("报告生成完成，\(report.count) 字符")
            let savedPath = try saveReport(report, resumePath: resumePath)
            log("报告已保存到 \(savedPath)")
            return Result(report: report, savedPath: savedPath)
        } catch {
            log("打分失败：\(error.localizedDescription)")
            throw error
        }
    }

    private static func expandTilde(_ path: String) -> String {
        path.hasPrefix("~") ? NSString(string: path).expandingTildeInPath : path
    }

    private static func mask(_ key: String) -> String {
        guard key.count > 10 else { return "***" }
        return String(key.prefix(6)) + "…" + String(key.suffix(4))
    }

    private static func log(_ msg: String) {
        NSLog("[AI打分] %@", msg)
    }

    // MARK: - 配置

    private static func loadEnv() -> [String: String] {
        guard let content = try? String(contentsOfFile: envPath, encoding: .utf8) else { return [:] }
        var vars: [String: String] = [:]
        for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value = String(value.dropFirst().dropLast())
            }
            vars[key] = value
        }
        return vars
    }

    /// 更新或新增 .env 中的一个键值，保留其他内容与注释
    static func updateEnv(key: String, value: String) throws {
        let url = URL(fileURLWithPath: envPath)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = existing.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var updated = false
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            guard let eq = t.firstIndex(of: "=") else { continue }
            let k = t[..<eq].trimmingCharacters(in: .whitespaces)
            if k == key {
                lines[i] = "\(key)=\(value)"
                updated = true
                break
            }
        }
        if !updated {
            lines.append("\(key)=\(value)")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - 简历读取

    private static func readResume(at path: String) throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            throw ScoreError.resumeNotFound(path)
        }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        log("读取简历，扩展名 \(ext)")
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url) else {
                throw ScoreError.resumeParseFailed(path)
            }
            var blocks: [String] = []
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i), let text = page.string, !text.isEmpty {
                    blocks.append(text)
                }
            }
            let joined = blocks.joined(separator: "\n")
            guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ScoreError.resumeParseFailed(path)
            }
            log("PDF 共 \(doc.pageCount) 页，提取 \(joined.count) 字符")
            return joined
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            log("文本简历读取到 \(text.count) 字符")
            return text
        }
        throw ScoreError.resumeParseFailed(path)
    }

    // MARK: - 网络请求

    private static func requestReport(apiKey: String, baseURL: String, jd: String, resume: String) async throws -> String {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/chat/completions") else {
            throw ScoreError.emptyReport
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "岗位要求（JD）：\n\(jd)\n\n候选人简历：\n\(resume)\n\n请严格按岗位要求给简历打分，并输出 markdown 格式的完整评分报告。"],
            ],
            "reasoning_effort": "high",
            "thinking": ["type": "enabled"],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        log("请求 DeepSeek：\(url.absoluteString)，model=\(model)，JD \(jd.count) 字符 / 简历 \(resume.count) 字符")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        log("HTTP 状态码：\(status)，响应字节 \(data.count)")
        if status != 200 {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ScoreError.http(status, text)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScoreError.emptyReport
        }
        return content
    }

    // MARK: - 保存

    private static func saveReport(_ report: String, resumePath: String) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        let base = (resumePath as NSString).lastPathComponent
        let name = (base as NSString).deletingPathExtension
        let path = outputDir + "/" + name + "_score.md"
        try report.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
}
