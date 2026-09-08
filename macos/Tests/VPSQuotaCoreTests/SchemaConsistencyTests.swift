import Foundation
import SQLite3
import Testing
@testable import VPSQuotaCore

/// `shared/schema.sql` 声称是两端建表语句的唯一事实源，但三份拷贝靠人工同步迟早会漂移。
/// 这组测试直接建一个真库，把它实际的表结构和 schema.sql 声明的对照，把约定变成保证。
///
/// Windows 端的 SqliteStore.cs 用的是同一段 SQL 文本，这里过了也就等于那边过了。
@Suite("Schema 一致性")
struct SchemaConsistencyTests {

    /// 从 schema.sql 里解析出「表名 → [(列名, 类型)]」，忽略注释与空白差异。
    private func declaredTables() throws -> [String: [(String, String)]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("shared/schema.sql")
        var sql = try String(contentsOf: url, encoding: .utf8)

        // 去掉 -- 行注释，它们只影响可读性，不影响结构
        sql = sql.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let range = line.range(of: "--") else { return String(line) }
                return String(line[..<range.lowerBound])
            }
            .joined(separator: "\n")

        var result: [String: [(String, String)]] = [:]
        let pattern = #"CREATE TABLE IF NOT EXISTS\s+(\w+)\s*\(([^;]*)\)\s*;"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(sql.startIndex..., in: sql)

        for match in regex.matches(in: sql, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: sql),
                  let bodyRange = Range(match.range(at: 2), in: sql) else { continue }
            let table = String(sql[nameRange])

            var columns: [(String, String)] = []
            for part in sql[bodyRange].split(separator: ",") {
                let tokens = part.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                // 跳过 PRIMARY KEY(...) 这类表级约束
                guard let first = tokens.first, first.uppercased() != "PRIMARY",
                      tokens.count >= 2 else { continue }
                columns.append((String(first), String(tokens[1]).uppercased()))
            }
            result[table] = columns
        }
        return result
    }

    /// 读真实数据库里的表结构。
    private func actualColumns(db: OpaquePointer, table: String) -> [(String, String)] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(stmt) }

        var result: [(String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let name = sqlite3_column_text(stmt, 1),
                  let type = sqlite3_column_text(stmt, 2) else { continue }
            result.append((String(cString: name), String(cString: type).uppercased()))
        }
        return result
    }

    @Test("实际建出来的表结构与 shared/schema.sql 逐列一致")
    func storeMatchesSharedSchema() async throws {
        let declared = try declaredTables()
        #expect(declared.keys.sorted() == ["daily_usage", "fetch_log"])

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vpsquota-schema-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("usage.sqlite")

        // 先让 SQLiteStore 按它自己的 migrate() 建库
        _ = try SQLiteStore(path: file)

        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let handle = try #require(db)

        for (table, expected) in declared {
            let actual = actualColumns(db: handle, table: table)
            #expect(
                actual.map(\.0) == expected.map(\.0),
                "表 \(table) 的列名与 shared/schema.sql 不一致"
            )
            #expect(
                actual.map(\.1) == expected.map(\.1),
                "表 \(table) 的列类型与 shared/schema.sql 不一致"
            )
        }
    }

    @Test("索引也一并建出来了")
    func indexesExist() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vpsquota-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("usage.sqlite")
        _ = try SQLiteStore(path: file)

        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(
            db, "SELECT name FROM sqlite_master WHERE type = 'index' ORDER BY name", -1, &stmt, nil
        ) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }

        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let n = sqlite3_column_text(stmt, 0) { names.append(String(cString: n)) }
        }
        #expect(names.contains("idx_daily_usage_day"))
        #expect(names.contains("idx_fetch_log_server"))
    }
}
