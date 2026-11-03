import GRDB
import Foundation
import PocketCastsUtils

class GRDBResultSet: PCDBResultSet {
    private let rowCursor: RowCursor
    private var row: Row!

    private var closed = false
    // Once the results have ended, by running out or by an error, they stay ended. After an error GRDB
    // doesn't mark its cursor done, and SQLite restarts the statement on the next step, so asking again
    // would begin over from the first row.
    private var isFinished = false

    init(rowCursor: RowCursor) {
        self.rowCursor = rowCursor
    }

    func close() {
        closed = true
    }

    func next() -> Bool {
        if closed {
            fatalError("Result set is closed")
        }

        if isFinished {
            row = nil
            return false
        }

        // Reset `row` before stepping so a cursor error (e.g. SQLITE_BUSY /
        // SQLITE_IOERR) surfaces as end-of-results instead of leaving the
        // previous row in place, which would make `while next()` loops spin.
        do {
            row = try rowCursor.next()
        } catch {
            // A cursor failure (SQLITE_BUSY/SQLITE_IOERR, etc.) silently
            // truncates the result set: callers see end-of-results and get
            // whatever rows were read so far. Log it so partial reads are
            // diagnosable rather than invisible.
            FileLog.shared.addMessage("GRDBResultSet.next() cursor error: \(error)")
            row = nil
        }
        if row == nil {
            isFinished = true
        }
        return row != nil
    }

    func int(forColumnIndex: Int32) -> Int32 {
        guard let valueForColumn = Array(row.databaseValues)[safe: Int(forColumnIndex)], let int32Value = Int32.fromDatabaseValue(valueForColumn) else {
            return 0
        }

        return int32Value
    }

    func int(forColumn: String) -> Int32 {
        row[forColumn]
    }

    func long(forColumn: String) -> Int {
        row[forColumn]
    }

    func long(forColumnIndex: Int32) -> Int {
        guard let valueForColumn = Array(row.databaseValues)[safe: Int(forColumnIndex)], let intValue = Int.fromDatabaseValue(valueForColumn) else {
            return 0
        }

        return intValue
    }

    func object(forColumn: String) -> Any? {
        row[forColumn]
    }

    func string(forColumn: String) -> String? {
        row[forColumn]
    }

    func longLongInt(forColumn: String) -> Int64 {
        row[forColumn] ?? 0
    }

    func bool(forColumn: String) -> Bool {
        row[forColumn] ?? false
    }

    func optionalBool(forColumn: String) -> Bool? {
        row[forColumn]
    }

    func double(forColumn: String) -> Double {
        // GRDB sometimes convert the date right away to a String
        // When casting back to double, it becomes the year, which mess up
        // the date. We deal with this special case here
        if row[forColumn] is String {
            return Date.fromDatabaseValue(row[forColumn])?.timeIntervalSince1970 ?? 0
        }

        return row[forColumn] ?? 0
    }

    func date(forColumn: String) -> Date? {
        row[forColumn]
    }
}
