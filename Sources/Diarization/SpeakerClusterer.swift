import Foundation

/// Groups points into `k` classes (k-means), with a silhouette score allowing
/// different values of `k` to be compared with each other and rejecting a split
/// when it isn't warranted.
///
/// The silhouette score (Rousseeuw, 1987) is the standard choice here precisely
/// because it stays comparable across different `k` values — unlike a simple
/// inter/intra-cluster distance ratio, whose scale depends on the number of
/// classes. This is what lets `MicrophoneDiarizer` try several `k` values and keep
/// the best one, rather than arbitrarily fixing a number of speakers.
enum SpeakerClusterer {
    struct Result {
        /// Cluster index for each point, in input order.
        let assignments: [Int]
        let clusterCount: Int
        /// Average silhouette score across points, in `[-1, 1]`. Close to 1:
        /// clearly separated classes. Close to 0 or negative: the split isn't
        /// warranted by the data.
        let silhouetteScore: Double
    }

    /// - Parameters:
    ///   - points: already-normalized vectors (see `normalize`).
    ///   - k: number of classes to form.
    static func cluster(points: [[Double]], k: Int) -> Result? {
        guard k >= 2, points.count >= k, let dimensions = points.first?.count, dimensions > 0
        else { return nil }

        var centroids = farthestFirstCentroids(points: points, k: k)
        var assignments = [Int](repeating: 0, count: points.count)

        for _ in 0..<10 {
            var changed = false
            for (index, point) in points.enumerated() {
                let assignment = nearestCentroid(point, among: centroids)
                if assignments[index] != assignment { changed = true }
                assignments[index] = assignment
            }

            for cluster in 0..<k {
                let members = points.indices.filter { assignments[$0] == cluster }
                guard !members.isEmpty else { continue }
                centroids[cluster] = average(members.map { points[$0] })
            }
            if !changed { break }
        }

        // An empty cluster signals a `k` too large for this data: no usable
        // result rather than a phantom class.
        guard Set(assignments).count == k else { return nil }

        let silhouette = silhouetteScore(points: points, assignments: assignments, k: k)
        return Result(assignments: assignments, clusterCount: k, silhouetteScore: silhouette)
    }

    /// Deterministic ("farthest-first") initialization: the first centroid is the
    /// most outlying point, subsequent ones maximize the minimum distance to
    /// already-chosen centroids. Reproducible, unlike a random draw.
    private static func farthestFirstCentroids(points: [[Double]], k: Int) -> [[Double]] {
        var centroids = [points[0]]
        while centroids.count < k {
            var farthestPoint = points[0]
            var farthestDistance = -1.0
            for point in points {
                let nearest = centroids.map { squaredDistance(point, $0) }.min() ?? 0
                if nearest > farthestDistance {
                    farthestDistance = nearest
                    farthestPoint = point
                }
            }
            centroids.append(farthestPoint)
        }
        return centroids
    }

    private static func nearestCentroid(_ point: [Double], among centroids: [[Double]]) -> Int {
        var best = 0
        var bestDistance = Double.infinity
        for (index, centroid) in centroids.enumerated() {
            let distance = squaredDistance(point, centroid)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    private static func silhouetteScore(points: [[Double]], assignments: [Int], k: Int) -> Double {
        guard points.count > k else { return 0 }
        let distances = points.map { point in points.map { squaredDistance(point, $0).squareRoot() } }

        var scores: [Double] = []
        for i in points.indices {
            let ownCluster = assignments[i]
            let sameCluster = points.indices.filter { $0 != i && assignments[$0] == ownCluster }
            guard !sameCluster.isEmpty else {
                scores.append(0)
                continue
            }
            let a = sameCluster.map { distances[i][$0] }.reduce(0, +) / Double(sameCluster.count)

            let b = (0..<k)
                .filter { $0 != ownCluster }
                .compactMap { other -> Double? in
                    let members = points.indices.filter { assignments[$0] == other }
                    guard !members.isEmpty else { return nil }
                    return members.map { distances[i][$0] }.reduce(0, +) / Double(members.count)
                }
                .min()

            guard let b else {
                scores.append(0)
                continue
            }
            scores.append((b - a) / max(a, b))
        }
        return scores.reduce(0, +) / Double(scores.count)
    }

    /// Standardizes each dimension across the set of points, so pitch (in Hz, large
    /// values) doesn't dominate the spectral centroid in the distance calculation,
    /// or vice versa.
    static func normalize(_ points: [[Double]]) -> [[Double]] {
        guard let dimensions = points.first?.count, dimensions > 0 else { return points }
        var means = [Double](repeating: 0, count: dimensions)
        var stddevs = [Double](repeating: 0, count: dimensions)

        for dimension in 0..<dimensions {
            let values = points.map { $0[dimension] }
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
            means[dimension] = mean
            stddevs[dimension] = variance.squareRoot()
        }

        return points.map { point in
            point.indices.map { dimension in
                stddevs[dimension] > 0.0001
                    ? (point[dimension] - means[dimension]) / stddevs[dimension]
                    : 0
            }
        }
    }

    private static func squaredDistance(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
    }

    private static func average(_ points: [[Double]]) -> [Double] {
        guard let dimensions = points.first?.count else { return [] }
        var sum = [Double](repeating: 0, count: dimensions)
        for point in points {
            for dimension in 0..<dimensions { sum[dimension] += point[dimension] }
        }
        return sum.map { $0 / Double(points.count) }
    }
}
