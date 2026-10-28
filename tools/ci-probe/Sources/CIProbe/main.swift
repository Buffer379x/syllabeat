import Foundation
import MLX
import MLXVLM
import WhisperKit

// Rechnet einmal auf der GPU und listet die eingebauten VLM-Konfigurationen.
let sum = MLXArray([1, 2, 3] as [Float]).sum().item(Float.self)
print("MLX-Summe: \(sum) · VLM-Konfigurationen: \(VLMRegistry.shared.models.count) · WhisperKit geladen: \(WhisperKit.self)")
