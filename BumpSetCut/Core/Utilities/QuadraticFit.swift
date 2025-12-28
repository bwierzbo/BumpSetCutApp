//
//  QuadraticFit.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 8/8/25.
//

import CoreGraphics

struct QuadraticFitResult {
    let a: CGFloat
    let b: CGFloat
    let c: CGFloat
    let r2: Double
}

func fitQuadratic(points: [CGPoint]) -> QuadraticFitResult? {
    guard points.count >= 3 else { return nil }
    
    var sumX: CGFloat = 0
    var sumX2: CGFloat = 0
    var sumX3: CGFloat = 0
    var sumX4: CGFloat = 0
    var sumY: CGFloat = 0
    var sumXY: CGFloat = 0
    var sumX2Y: CGFloat = 0
    
    for p in points {
        let x = p.x
        let y = p.y
        let x2 = x * x
        let x3 = x2 * x
        let x4 = x3 * x
        
        sumX += x
        sumX2 += x2
        sumX3 += x3
        sumX4 += x4
        sumY += y
        sumXY += x * y
        sumX2Y += x2 * y
    }
    
    let n = CGFloat(points.count)
    let matrix = [
        [sumX4, sumX3, sumX2],
        [sumX3, sumX2, sumX],
        [sumX2, sumX,  n    ]
    ]
    let rhs = [sumX2Y, sumXY, sumY]
    
    guard let coeffs = solve3x3(matrix: matrix, rhs: rhs) else { return nil }
    
    // R²
    let meanY = sumY / n
    let ssTot = points.reduce(CGFloat(0)) { $0 + pow($1.y - meanY, 2) }
    let ssRes = points.reduce(CGFloat(0)) { $0 + pow($1.y - (coeffs[0] * $1.x * $1.x + coeffs[1] * $1.x + coeffs[2]), 2) }
    let r2 = 1 - (Double(ssRes) / Double(ssTot))
    
    return QuadraticFitResult(a: coeffs[0], b: coeffs[1], c: coeffs[2], r2: r2)
}

private func solve3x3(matrix: [[CGFloat]], rhs: [CGFloat]) -> [CGFloat]? {
    var m = matrix
    var r = rhs
    
    for i in 0..<3 {
        var maxRow = i
        for k in i+1..<3 {
            if abs(m[k][i]) > abs(m[maxRow][i]) {
                maxRow = k
            }
        }
        if maxRow != i {
            m.swapAt(i, maxRow)
            r.swapAt(i, maxRow)
        }
        
        let pivot = m[i][i]
        guard pivot != 0 else { return nil }
        for j in i..<3 { m[i][j] /= pivot }
        r[i] /= pivot
        
        for k in 0..<3 {
            if k != i {
                let factor = m[k][i]
                for j in i..<3 {
                    m[k][j] -= factor * m[i][j]
                }
                r[k] -= factor * r[i]
            }
        }
    }
    return r
}
