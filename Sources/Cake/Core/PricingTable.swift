import Foundation

/// 模型定价表。
///
/// 单价单位：USD / 每百万 token。PoC 内置少量条目；
/// 正式版对标 ccusage 用 LiteLLM 定价，支持离线与自定义覆盖。
struct PricingTable: Sendable {
    static let shared = PricingTable()

    struct Rate: Sendable {
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheCreate: Double
    }

    /// 以模型 ID 的子串匹配（应对 "global.anthropic.claude-opus-4-8[1m]" 这类长 ID）。
    private let rates: [(needle: String, rate: Rate)] = [
        ("opus",   Rate(input: 15.0, output: 75.0, cacheRead: 1.5,  cacheCreate: 18.75)),
        ("sonnet", Rate(input: 3.0,  output: 15.0, cacheRead: 0.3,  cacheCreate: 3.75)),
        ("haiku",  Rate(input: 0.8,  output: 4.0,  cacheRead: 0.08, cacheCreate: 1.0)),
        // OpenAI（Codex 常用模型，单价为公开参考价，可能随官方调整）
        ("gpt-5",  Rate(input: 1.25, output: 10.0, cacheRead: 0.125, cacheCreate: 0)),
        ("o3",     Rate(input: 2.0,  output: 8.0,  cacheRead: 0.5,   cacheCreate: 0)),
        ("o4",     Rate(input: 1.1,  output: 4.4,  cacheRead: 0.275, cacheCreate: 0)),
        ("gpt-4o", Rate(input: 2.5,  output: 10.0, cacheRead: 1.25,  cacheCreate: 0)),
    ]

    func cost(for model: String?, tokens: TokenCounters) -> Double? {
        guard let model else { return nil }
        let lowered = model.lowercased()
        guard let entry = rates.first(where: { lowered.contains($0.needle) }) else { return nil }
        let r = entry.rate
        let perMillion = 1_000_000.0
        return Double(tokens.input)       / perMillion * r.input
             + Double(tokens.output)      / perMillion * r.output
             + Double(tokens.cacheRead)   / perMillion * r.cacheRead
             + Double(tokens.cacheCreate) / perMillion * r.cacheCreate
    }
}
