import Accelerate
import Foundation

/// 把新找到的脸归到人物里。只动还没归属的脸，用户的决定（命名、“不是 TA”）不被推翻。
///
/// 做法：每个人物用它所有脸特征的平均方向（中心）代表。新脸和所有中心比，够像就归进去、更新中心；
/// 都不像就自成一个未命名的人物。最后把彼此很像的未命名人物合并（也可以并进有名字的人物），
/// 两个有名字的人物从不自动合并。比的是余弦相似度，十万张照片约三四万张脸、几千个人物，用矩阵乘一次算完。
public struct FaceClusterer: Sendable {
    /// 新脸和人物中心的相似度达到这个值就归进去。真实库上 0.3–0.5 分出的组几乎一样，取中间。
    public var assignThreshold: Float = 0.4
    /// 两个人物中心的相似度达到这个值就合并。
    public var mergeThreshold: Float = 0.5

    public init() {}

    public struct Person: Sendable, Equatable {
        public var id: Int64
        public var isNamed: Bool
        /// 特征之和（没有归一化），加一张脸就加上它的特征。
        public var sum: [Float]
        public var count: Int
        public init(id: Int64, isNamed: Bool, sum: [Float], count: Int) {
            self.id = id
            self.isNamed = isNamed
            self.sum = sum
            self.count = count
        }
    }

    public struct NewFace: Sendable {
        public var id: Int64
        public var feature: [Float]
        /// 用户说过“不是 TA”的人物，不再归进去。
        public var rejectedPerson: Int64?
        public init(id: Int64, feature: [Float], rejectedPerson: Int64? = nil) {
            self.id = id
            self.feature = feature
            self.rejectedPerson = rejectedPerson
        }
    }

    public struct Result: Sendable, Equatable {
        /// 脸 → 已有人物。
        public var assigned: [Int64: Int64] = [:]
        /// 新建的人物（未命名），每个是一组脸。
        public var newPeople: [[Int64]] = []
        /// 并进别的人物的未命名人物：被并的 → 并入的（都是已有人物）。
        public var merged: [Int64: Int64] = [:]
    }

    public func cluster(_ faces: [NewFace], into people: [Person]) -> Result {
        // 临时编号：已有人物用自己的 id，新人物用负数，最后再换。
        var clusters = people.map { Cluster(id: $0.id, isNamed: $0.isNamed, sum: $0.sum, count: $0.count, faces: []) }
        var nextTemporary: Int64 = -1
        for face in faces {
            var best = -1
            var bestSimilarity = assignThreshold
            for (index, cluster) in clusters.enumerated() where cluster.id != face.rejectedPerson {
                let similarity = cluster.similarity(to: face.feature)
                if similarity >= bestSimilarity {
                    bestSimilarity = similarity
                    best = index
                }
            }
            if best >= 0 {
                clusters[best].add(face)
            } else {
                var cluster = Cluster(id: nextTemporary, isNamed: false, sum: [Float](repeating: 0, count: face.feature.count), count: 0, faces: [])
                nextTemporary -= 1
                cluster.add(face)
                clusters.append(cluster)
            }
        }

        // 合并：未命名的并进最像的那个（有名字的优先保留），反复做直到没有可以并的。
        var result = Result()
        var alive = Array(repeating: true, count: clusters.count)
        var changed = true
        while changed {
            changed = false
            let centers = clusters.map { $0.center }
            let similarities = Self.similarityMatrix(centers)
            let count = clusters.count
            var pairs: [(Float, Int, Int)] = []
            for i in 0..<count where alive[i] {
                for j in (i + 1)..<count where alive[j] && !(clusters[i].isNamed && clusters[j].isNamed) {
                    let value = similarities[i * count + j]
                    if value >= mergeThreshold { pairs.append((value, i, j)) }
                }
            }
            pairs.sort { $0.0 > $1.0 }
            var touched = Set<Int>()
            for (_, i, j) in pairs where !touched.contains(i) && !touched.contains(j) {
                // 并入有名字的；都没名字时并入已有的、再并入大的。
                let (keep, drop) = Self.mergeOrder(clusters[i], i, clusters[j], j)
                if clusters[drop].faces.contains(where: { $0.rejectedPerson == clusters[keep].id }) { continue }
                clusters[keep].absorb(clusters[drop])
                if clusters[drop].id > 0 {
                    // 已有人物被并：记下来，之前并进它的也改指过来。
                    result.merged[clusters[drop].id] = clusters[keep].id
                    for (from, to) in result.merged where to == clusters[drop].id { result.merged[from] = clusters[keep].id }
                }
                alive[drop] = false
                touched.formUnion([i, j])
                changed = true
            }
        }

        for (index, cluster) in clusters.enumerated() where alive[index] {
            if cluster.id > 0 {
                for face in cluster.faces { result.assigned[face.id] = cluster.id }
            } else if !cluster.faces.isEmpty {
                result.newPeople.append(cluster.faces.map(\.id))
            }
        }
        // 并进已有人物的新脸已经在 faces 里；被并掉的已有人物，它原来的脸由调用方按 merged 改。
        return result
    }

    private struct Cluster {
        var id: Int64
        var isNamed: Bool
        var sum: [Float]
        var count: Int
        var faces: [NewFace]

        var center: [Float] { FaceMath.normalized(sum) }

        func similarity(to feature: [Float]) -> Float {
            guard count > 0 else { return -1 }
            var dot: Float = 0, norm: Float = 0
            vDSP_dotpr(sum, 1, feature, 1, &dot, vDSP_Length(feature.count))
            vDSP_svesq(sum, 1, &norm, vDSP_Length(sum.count))
            return norm > 0 ? dot / norm.squareRoot() : -1
        }

        mutating func add(_ face: NewFace) {
            vDSP_vadd(sum, 1, face.feature, 1, &sum, 1, vDSP_Length(sum.count))
            count += 1
            faces.append(face)
        }

        mutating func absorb(_ other: Cluster) {
            vDSP_vadd(sum, 1, other.sum, 1, &sum, 1, vDSP_Length(sum.count))
            count += other.count
            faces += other.faces
        }
    }

    private static func mergeOrder(_ a: Cluster, _ i: Int, _ b: Cluster, _ j: Int) -> (keep: Int, drop: Int) {
        if a.isNamed != b.isNamed { return a.isNamed ? (i, j) : (j, i) }
        if (a.id > 0) != (b.id > 0) { return a.id > 0 ? (i, j) : (j, i) }
        return a.count >= b.count ? (i, j) : (j, i)
    }

    /// 中心两两的余弦相似度，按行排成一维。
    static func similarityMatrix(_ centers: [[Float]]) -> [Float] {
        let count = centers.count
        guard count > 0, let length = centers.first?.count, length > 0 else { return [] }
        var matrix = [Float](repeating: 0, count: count * length)
        for (row, center) in centers.enumerated() where center.count == length {
            matrix.replaceSubrange(row * length..<(row + 1) * length, with: center)
        }
        var output = [Float](repeating: 0, count: count * count)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(count), Int32(count), Int32(length),
                    1, matrix, Int32(length), matrix, Int32(length), 0, &output, Int32(count))
        return output
    }
}
