import Foundation

/// Regroupe des points en `k` classes (k-means), avec un score de silhouette
/// permettant de comparer différentes valeurs de `k` entre elles et de refuser la
/// scission quand elle n'est pas justifiée.
///
/// Le score de silhouette (Rousseeuw, 1987) est le choix standard ici précisément
/// parce qu'il reste comparable d'un `k` à l'autre — contrairement à un simple
/// rapport distance inter/intra-cluster, dont l'échelle dépend du nombre de
/// classes. C'est ce qui permet à `MicrophoneDiarizer` d'essayer plusieurs `k` et de
/// garder le meilleur, plutôt que de figer arbitrairement un nombre de locuteurs.
enum SpeakerClusterer {
    struct Result {
        /// Index de cluster pour chaque point, dans l'ordre d'entrée.
        let assignments: [Int]
        let clusterCount: Int
        /// Moyenne des scores de silhouette par point, dans `[-1, 1]`. Proche de 1 :
        /// classes nettement séparées. Proche de 0 ou négatif : la scission n'est
        /// pas justifiée par les données.
        let silhouetteScore: Double
    }

    /// - Parameters:
    ///   - points: vecteurs déjà normalisés (voir `normalize`).
    ///   - k: nombre de classes à former.
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

        // Un cluster vide signale un `k` trop grand pour ces données : pas de
        // résultat exploitable plutôt qu'une classe fantôme.
        guard Set(assignments).count == k else { return nil }

        let silhouette = silhouetteScore(points: points, assignments: assignments, k: k)
        return Result(assignments: assignments, clusterCount: k, silhouetteScore: silhouette)
    }

    /// Initialisation déterministe (« farthest-first ») : le premier centroïde est le
    /// point le plus excentré, les suivants maximisent la distance minimale aux
    /// centroïdes déjà choisis. Reproductible, contrairement à un tirage aléatoire.
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

    /// Centre-réduit chaque dimension sur l'ensemble des points, pour que la hauteur
    /// (en Hz, grandes valeurs) ne domine pas le centroïde spectral dans le calcul de
    /// distance, ou l'inverse.
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
