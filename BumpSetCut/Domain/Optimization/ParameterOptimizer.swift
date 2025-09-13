//
//  ParameterOptimizer.swift
//  BumpSetCut
//
//  Created for Detection Logic Upgrades - Issue #24
//

import Foundation

final class ParameterOptimizer {
    
    enum OptimizationAlgorithm {
        case gridSearch
        case randomSearch
        case bayesian
    }
    
    struct OptimizationConfig {
        let algorithm: OptimizationAlgorithm
        let maxIterations: Int
        let targetMetric: String
        let improvementThreshold: Double
        
        static let `default` = OptimizationConfig(
            algorithm: .gridSearch,
            maxIterations: 100,
            targetMetric: "f1_score",
            improvementThreshold: 0.01
        )
    }
    
    struct OptimizationResult {
        let bestParameters: [String: Double]
        let bestScore: Double
        let iterations: Int
        let convergenceReached: Bool
        let recommendations: [String]
    }
    
    private let config: OptimizationConfig
    
    init(config: OptimizationConfig = .default) {
        self.config = config
    }
    
    func optimizeParameters(
        parameterBounds: [String: (min: Double, max: Double)],
        evaluationFunction: ([String: Double]) -> Double
    ) async -> OptimizationResult {
        
        switch config.algorithm {
        case .gridSearch:
            return await gridSearchOptimization(parameterBounds: parameterBounds, evaluationFunction: evaluationFunction)
        case .randomSearch:
            return await randomSearchOptimization(parameterBounds: parameterBounds, evaluationFunction: evaluationFunction)
        case .bayesian:
            return await bayesianOptimization(parameterBounds: parameterBounds, evaluationFunction: evaluationFunction)
        }
    }
    
    private func gridSearchOptimization(
        parameterBounds: [String: (min: Double, max: Double)],
        evaluationFunction: ([String: Double]) -> Double
    ) async -> OptimizationResult {
        
        var bestParameters: [String: Double] = [:]
        var bestScore: Double = -Double.infinity
        var iterations = 0
        
        let gridResolution = max(2, Int(pow(Double(config.maxIterations), 1.0 / Double(parameterBounds.count))))
        
        func generateGrid(parameters: [String], bounds: [String: (min: Double, max: Double)]) -> [[String: Double]] {
            guard let firstParam = parameters.first else {
                return [[:]]
            }
            
            let remainingParams = Array(parameters.dropFirst())
            let remainingCombinations = generateGrid(parameters: remainingParams, bounds: bounds)
            
            let (min, max) = bounds[firstParam]!
            let step = (max - min) / Double(gridResolution - 1)
            
            var combinations: [[String: Double]] = []
            for i in 0..<gridResolution {
                let value = min + Double(i) * step
                for var combination in remainingCombinations {
                    combination[firstParam] = value
                    combinations.append(combination)
                }
            }
            
            return combinations
        }
        
        let parameterNames = Array(parameterBounds.keys)
        let gridCombinations = generateGrid(parameters: parameterNames, bounds: parameterBounds)
        
        for combination in gridCombinations.prefix(config.maxIterations) {
            let score = evaluationFunction(combination)
            iterations += 1
            
            if score > bestScore {
                bestScore = score
                bestParameters = combination
            }
        }
        
        return OptimizationResult(
            bestParameters: bestParameters,
            bestScore: bestScore,
            iterations: iterations,
            convergenceReached: iterations >= config.maxIterations,
            recommendations: generateRecommendations(bestParameters)
        )
    }
    
    private func randomSearchOptimization(
        parameterBounds: [String: (min: Double, max: Double)],
        evaluationFunction: ([String: Double]) -> Double
    ) async -> OptimizationResult {
        
        var bestParameters: [String: Double] = [:]
        var bestScore: Double = -Double.infinity
        var iterations = 0
        
        for _ in 0..<config.maxIterations {
            var randomParameters: [String: Double] = [:]
            
            for (param, bounds) in parameterBounds {
                let randomValue = Double.random(in: bounds.min...bounds.max)
                randomParameters[param] = randomValue
            }
            
            let score = evaluationFunction(randomParameters)
            iterations += 1
            
            if score > bestScore {
                bestScore = score
                bestParameters = randomParameters
            }
        }
        
        return OptimizationResult(
            bestParameters: bestParameters,
            bestScore: bestScore,
            iterations: iterations,
            convergenceReached: true,
            recommendations: generateRecommendations(bestParameters)
        )
    }
    
    private func bayesianOptimization(
        parameterBounds: [String: (min: Double, max: Double)],
        evaluationFunction: ([String: Double]) -> Double
    ) async -> OptimizationResult {
        
        // Simplified Bayesian optimization using random search with exploitation/exploration
        var bestParameters: [String: Double] = [:]
        var bestScore: Double = -Double.infinity
        var iterations = 0
        var evaluatedPoints: [([String: Double], Double)] = []
        
        // Initial random sampling
        let initialSamples = min(10, config.maxIterations / 2)
        
        for _ in 0..<initialSamples {
            var randomParameters: [String: Double] = [:]
            
            for (param, bounds) in parameterBounds {
                let randomValue = Double.random(in: bounds.min...bounds.max)
                randomParameters[param] = randomValue
            }
            
            let score = evaluationFunction(randomParameters)
            evaluatedPoints.append((randomParameters, score))
            iterations += 1
            
            if score > bestScore {
                bestScore = score
                bestParameters = randomParameters
            }
        }
        
        // Exploitation phase - sample around best points
        for _ in initialSamples..<config.maxIterations {
            var exploitParameters: [String: Double] = [:]
            
            // Add noise around best parameters
            for (param, bestValue) in bestParameters {
                let bounds = parameterBounds[param]!
                let noise = (bounds.max - bounds.min) * 0.1 * Double.random(in: -1...1)
                let newValue = max(bounds.min, min(bounds.max, bestValue + noise))
                exploitParameters[param] = newValue
            }
            
            let score = evaluationFunction(exploitParameters)
            evaluatedPoints.append((exploitParameters, score))
            iterations += 1
            
            if score > bestScore {
                bestScore = score
                bestParameters = exploitParameters
            }
        }
        
        return OptimizationResult(
            bestParameters: bestParameters,
            bestScore: bestScore,
            iterations: iterations,
            convergenceReached: true,
            recommendations: generateRecommendations(bestParameters)
        )
    }
    
    private func generateRecommendations(_ parameters: [String: Double]) -> [String] {
        var recommendations: [String] = []
        
        if let r2 = parameters["enhancedMinR2"], r2 < 0.8 {
            recommendations.append("Consider increasing R² threshold for better trajectory quality")
        }
        
        if let confidence = parameters["minClassificationConfidence"], confidence < 0.7 {
            recommendations.append("Increase classification confidence for more reliable detection")
        }
        
        return recommendations
    }
}