import Foundation

/// Regroupe des points en 2 classes (k-means, k fixé), avec un score de séparation
/// permettant de refuser la scission quand elle n'est pas justifiée.
///
/// Fixer k=2 est une limite assumée du premier jet : il suppose au plus deux
/// locuteurs sur la piste micro. Une réunion à trois personnes autour d'un micro
/// serait mal servie (l'un des deux groupes mélangerait deux voix). Voir le README
/// du module pour la suite envisagée.
enum SpeakerClusterer {
    struct Result {
        /// Index de cluster (0 ou 1) pour chaque point, dans l'ordre d'entrée.
        let assignments: [Int]
        /// Rapport distance inter-clusters / dispersion intra-cluster. Plus c'est
        /// grand, plus la scission est franche.
        let separationScore: Double
    }

    /// - Parameter points: vecteurs déjà normalisés (voir `normalize`).
    static func cluster(points: [[Double]]) -> Result? {
        guard points.count >= 2, let dimensions = points.first?.count, dimensions > 0 else {
            return nil
        }

        // Initialisation déterministe : les deux points les plus éloignés l'un de
        // l'autre, pour ne pas dépendre d'un tirage aléatoire (reproductible en test).
        var farthestPair = (0, 1)
        var farthestDistance = -1.0
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                let distance = squaredDistance(points[i], points[j])
                if distance > farthestDistance {
                    farthestDistance = distance
                    farthestPair = (i, j)
                }
            }
        }

        var centroids = [points[farthestPair.0], points[farthestPair.1]]
        var assignments = [Int](repeating: 0, count: points.count)

        for _ in 0..<10 {
            var changed = false
            for (index, point) in points.enumerated() {
                let d0 = squaredDistance(point, centroids[0])
                let d1 = squaredDistance(point, centroids[1])
                let assignment = d0 <= d1 ? 0 : 1
                if assignments[index] != assignment { changed = true }
                assignments[index] = assignment
            }

            for cluster in 0...1 {
                let members = points.indices.filter { assignments[$0] == cluster }
                guard !members.isEmpty else { continue }
                centroids[cluster] = average(members.map { points[$0] })
            }
            if !changed { break }
        }

        // Sans les deux classes effectivement peuplées, il n'y a rien à séparer.
        guard assignments.contains(0), assignments.contains(1) else { return nil }

        let interClusterDistance = squaredDistance(centroids[0], centroids[1]).squareRoot()
        let intraClusterSpread = (0...1).map { cluster -> Double in
            let members = points.indices.filter { assignments[$0] == cluster }
            let distances = members.map { squaredDistance(points[$0], centroids[cluster]).squareRoot() }
            return distances.reduce(0, +) / Double(max(distances.count, 1))
        }
        let averageSpread = (intraClusterSpread[0] + intraClusterSpread[1]) / 2
        let separationScore = averageSpread > 0.0001 ? interClusterDistance / averageSpread : 0

        return Result(assignments: assignments, separationScore: separationScore)
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
