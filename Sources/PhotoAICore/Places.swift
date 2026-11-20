import CoreLocation
import Foundation
import MapKit

/// 坐标转成的地名。
public struct PlaceInfo: Sendable, Equatable {
    /// 侧栏、检查器显示的名字：城市（如“杭州市”），没有城市时用国家或地区。
    public var name: String
    /// 完整的地址（如“中国浙江省杭州市西湖区 西湖街道”），搜索用。
    public var detail: String

    public init(name: String, detail: String) {
        self.name = name
        self.detail = detail
    }
}

/// 坐标 → 地名。软件里用 Apple 的反向地理编码，测试里换成假的。
public protocol ReverseGeocoder: Sendable {
    /// 没有地名时返回 nil；联网失败、被限流时抛错，下次再试。
    func place(latitude: Double, longitude: Double) async throws -> PlaceInfo?
}

/// Apple 的反向地理编码（MapKit）：免费、要联网，会把坐标发给 Apple，有频率限制（产品定位 §6）。
public struct AppleReverseGeocoder: ReverseGeocoder {
    public init() {}

    public func place(latitude: Double, longitude: Double) async throws -> PlaceInfo? {
        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude)) else {
            return nil
        }
        request.preferredLocale = Locale(identifier: "zh-Hans")
        guard let item = try await request.mapItems.first else { return nil }
        let representations = item.addressRepresentations
        guard let name = representations?.cityName ?? representations?.regionName else { return nil }
        let detail = [item.address?.fullAddress, item.name].compactMap { $0 }.joined(separator: " ")
        return PlaceInfo(name: name, detail: detail.isEmpty ? name : detail)
    }
}

/// 地点：有名字的城市和照片数（侧栏“地点”）。
public struct PlaceSummary: Sendable, Equatable, Hashable {
    public var name: String
    public var photoCount: Int
}

extension LibraryReader {
    /// 有可见照片的地名，照片多的在前。
    public func places() throws -> [PlaceSummary] {
        try db.all(
            """
            SELECT pl.name, COUNT(*) FROM photos p JOIN places pl ON pl.geo_cell = p.geo_cell
            WHERE p.present_location_count > 0 AND pl.state = 'found'
            GROUP BY pl.name ORDER BY COUNT(*) DESC, pl.name;
            """
        ) { PlaceSummary(name: $0.text(0) ?? "", photoCount: $0.int(1)) }
    }

    public func place(of photo: PhotoID) throws -> PlaceInfo? {
        try db.first(
            "SELECT pl.name, pl.detail FROM photos p JOIN places pl ON pl.geo_cell = p.geo_cell WHERE p.id = ? AND pl.state = 'found';",
            [photo]
        ) { PlaceInfo(name: $0.text(0) ?? "", detail: $0.text(1) ?? "") }
    }

    /// 还没查过地名的网格（可见照片的），每个带一个坐标。失败过的也算，下次再试。
    public func geoCellsNeedingPlaces(limit: Int, excluding: Set<String> = []) throws -> [(cell: String, latitude: Double, longitude: Double)] {
        try db.all(
            """
            SELECT p.geo_cell, AVG(p.latitude), AVG(p.longitude) FROM photos p
            LEFT JOIN places pl ON pl.geo_cell = p.geo_cell
            WHERE p.geo_cell IS NOT NULL AND p.present_location_count > 0 AND (pl.geo_cell IS NULL OR pl.state = 'failed')
            GROUP BY p.geo_cell ORDER BY MAX(p.id) DESC;
            """
        ) { (cell: $0.text(0) ?? "", latitude: $0.double(1), longitude: $0.double(2)) }
            .filter { !excluding.contains($0.cell) }
            .prefix(limit)
            .map { $0 }
    }

    /// 地点的进度：有坐标的可见照片里，网格已经查过（找到或确认没有）的张数。
    public func placeCounts() throws -> AnalysisCounts {
        var counts = AnalysisCounts()
        try db.query(
            """
            SELECT pl.state, COUNT(*) FROM photos p LEFT JOIN places pl ON pl.geo_cell = p.geo_cell
            WHERE p.present_location_count > 0 AND p.latitude IS NOT NULL GROUP BY 1;
            """
        ) { row in
            switch row.text(0) {
            case "found", "none": counts.done += row.int(1)
            case "failed": counts.failed += row.int(1)
            default: counts.pending += row.int(1)
            }
        }
        return counts
    }
}

extension Library {
    /// 有坐标的照片算出网格：坐标取两位小数（纬度方向约 1.1 公里）。
    @discardableResult
    public func assignGeoCells() throws -> Int {
        try db.run(
            """
            UPDATE photos SET geo_cell = printf('%.2f,%.2f', latitude, longitude)
            WHERE latitude IS NOT NULL AND longitude IS NOT NULL AND geo_cell IS NULL;
            """
        )
    }

    /// 记下一个网格的地名；`place` 为 nil 表示查过、没有地名。
    public func savePlace(_ cell: String, place: PlaceInfo?) throws {
        try db.run(
            "INSERT OR REPLACE INTO places (geo_cell, name, detail, state, fetched_at) VALUES (?, ?, ?, ?, ?);",
            [cell, place?.name, place?.detail, place == nil ? "none" : "found", now()]
        )
    }

    public func markPlaceFailed(_ cell: String) throws {
        try db.run(
            "INSERT OR REPLACE INTO places (geo_cell, name, detail, state, fetched_at) VALUES (?, NULL, NULL, 'failed', ?);",
            [cell, now()]
        )
    }
}

/// 地名的后台队列：一个网格查一次，两次请求之间隔开，不撞 Apple 的频率限制。默认关闭。
public struct PlaceRunner: Sendable {
    public struct Progress: Sendable, Equatable {
        public var found = 0
        public var none = 0
        public var failed = 0
    }

    public var library: Library
    public var geocoder: any ReverseGeocoder
    public var interval: Duration

    public init(library: Library, geocoder: any ReverseGeocoder = AppleReverseGeocoder(), interval: Duration = .seconds(1.5)) {
        self.library = library
        self.geocoder = geocoder
        self.interval = interval
    }

    public func run(
        shouldStop: @escaping @Sendable () -> Bool = { Task.isCancelled },
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Progress {
        try library.assignGeoCells()
        var total = Progress()
        var tried: Set<String> = []
        var consecutiveFailures = 0
        while !shouldStop() {
            let cells = try library.reader.geoCellsNeedingPlaces(limit: 20, excluding: tried)
            if cells.isEmpty { break }
            for cell in cells {
                if shouldStop() { break }
                tried.insert(cell.cell)
                do {
                    let place = try await geocoder.place(latitude: cell.latitude, longitude: cell.longitude)
                    try library.savePlace(cell.cell, place: place)
                    if place == nil { total.none += 1 } else { total.found += 1 }
                    consecutiveFailures = 0
                } catch let error as DatabaseError {
                    throw error
                } catch {
                    try library.markPlaceFailed(cell.cell)
                    total.failed += 1
                    consecutiveFailures += 1
                }
                progress?(total)
                // 连续失败多半是没联网或被限流：这一轮先停，下次启动再试。
                if consecutiveFailures >= 5 { return total }
                try? await Task.sleep(for: interval)
            }
        }
        return total
    }
}
