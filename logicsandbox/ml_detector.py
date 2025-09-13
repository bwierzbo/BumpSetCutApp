"""
Real ML Model Detector

Direct integration with bestv2.mlpackage for actual volleyball detection.
No mock simulation - only real ML model inference.
"""

import os
import sys
from typing import Optional, Tuple, List, Dict, Any
import json

try:
    import coremltools as ct
    import numpy as np
    import cv2
    DEPS_AVAILABLE = True
except ImportError as e:
    DEPS_AVAILABLE = False
    print(f"❌ Required dependencies not available: {e}")
    print("Install with: pip install coremltools opencv-python numpy")
    sys.exit(1)


class BestV2Detector:
    """
    Real volleyball detection using bestv2.mlpackage from BumpSetCut iOS app.
    """
    
    def __init__(self, model_path: Optional[str] = None):
        self.model = None
        self.model_path = model_path
        self.input_shape = None
        self.output_spec = None
        
        # Detection parameters (matching iOS app)
        self.confidence_threshold = 0.3
        self.nms_threshold = 0.4
        self.input_size = (640, 640)  # Standard YOLO input
        
        self._find_and_load_model()
    
    def _find_and_load_model(self):
        """Find and load the bestv2.mlpackage model."""
        if not self.model_path:
            # Search for model in iOS app bundle
            search_paths = [
                "../BumpSetCut/Resources/ML/bestv2.mlpackage",
                "../../BumpSetCut/Resources/ML/bestv2.mlpackage",
                "../BumpSetCut/BumpSetCut/Resources/ML/bestv2.mlpackage",
                "../../BumpSetCut/BumpSetCut/Resources/ML/bestv2.mlpackage"
            ]
            
            for path in search_paths:
                full_path = os.path.abspath(path)
                if os.path.exists(full_path):
                    self.model_path = full_path
                    break
        
        if not self.model_path or not os.path.exists(self.model_path):
            print("❌ bestv2.mlpackage model not found!")
            print("Searched paths:")
            for path in search_paths:
                print(f"   {os.path.abspath(path)}")
            sys.exit(1)
        
        print(f"📦 Loading bestv2.mlpackage from: {self.model_path}")
        
        try:
            self.model = ct.models.MLModel(self.model_path)
            self._analyze_model_spec()
            print("✅ Model loaded successfully!")
            
        except Exception as e:
            print(f"❌ Failed to load model: {e}")
            sys.exit(1)
    
    def _analyze_model_spec(self):
        """Analyze model specification to understand input/output format."""
        spec = self.model.get_spec()
        
        # Extract input information
        if spec.description.input:
            input_desc = spec.description.input[0]
            print(f"   Input: {input_desc.name}")
            
            if hasattr(input_desc.type, 'imageType'):
                img_type = input_desc.type.imageType
                self.input_shape = (img_type.height, img_type.width, 3)
                print(f"   Expected input shape: {self.input_shape}")
            elif hasattr(input_desc.type, 'multiArrayType'):
                array_type = input_desc.type.multiArrayType
                self.input_shape = tuple(array_type.shape)
                print(f"   Expected input shape: {self.input_shape}")
        
        # Extract output information
        outputs = []
        for output_desc in spec.description.output:
            outputs.append({
                'name': output_desc.name,
                'type': str(output_desc.type).split()[0]
            })
        
        self.output_spec = outputs
        print(f"   Outputs: {[out['name'] for out in outputs]}")
    
    def detect_volleyball(self, frame: np.ndarray) -> List[Dict[str, Any]]:
        """
        Detect volleyball in frame using real ML model.
        
        Args:
            frame: Input video frame (H, W, C) in BGR format
            
        Returns:
            List of detections with bbox, confidence, etc.
        """
        if self.model is None:
            return []
        
        # Preprocess frame
        processed_input = self._preprocess_frame(frame)
        
        # Run inference
        try:
            predictions = self.model.predict({'image': processed_input})
        except Exception as e:
            print(f"⚠️  Inference failed: {e}")
            return []
        
        # Post-process predictions
        detections = self._postprocess_predictions(predictions, frame.shape)
        
        return detections
    
    def _preprocess_frame(self, frame: np.ndarray) -> np.ndarray:
        """
        Preprocess frame for YOLO model input.
        Matches the preprocessing in YOLODetector.swift.
        """
        # Convert BGR to RGB
        rgb_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        
        # Resize to model input size
        resized = cv2.resize(rgb_frame, self.input_size)
        
        # Normalize to 0-1
        normalized = resized.astype(np.float32) / 255.0
        
        # Add batch dimension if needed
        if len(normalized.shape) == 3:
            normalized = np.expand_dims(normalized, axis=0)
        
        return normalized
    
    def _postprocess_predictions(self, predictions: Dict, original_shape: Tuple) -> List[Dict[str, Any]]:
        """
        Post-process YOLO predictions to extract volleyball detections.
        """
        detections = []
        orig_h, orig_w = original_shape[:2]
        
        # Handle different output formats
        for key, output in predictions.items():
            if isinstance(output, np.ndarray):
                # Typical YOLO output: [batch, num_detections, 85] 
                # Format: [x_center, y_center, width, height, confidence, class0, class1, ...]
                
                if output.ndim == 3:
                    batch_detections = output[0]  # Remove batch dimension
                elif output.ndim == 2:
                    batch_detections = output
                else:
                    continue
                
                for detection in batch_detections:
                    if len(detection) >= 5:
                        x_center, y_center, width, height, confidence = detection[:5]
                        
                        # Filter by confidence
                        if confidence >= self.confidence_threshold:
                            # Convert from normalized coordinates to pixel coordinates
                            x_center_px = x_center * orig_w
                            y_center_px = y_center * orig_h
                            width_px = width * orig_w
                            height_px = height * orig_h
                            
                            # Convert to bbox format (x1, y1, x2, y2)
                            x1 = int(x_center_px - width_px / 2)
                            y1 = int(y_center_px - height_px / 2)
                            x2 = int(x_center_px + width_px / 2)
                            y2 = int(y_center_px + height_px / 2)
                            
                            # Clamp to image bounds
                            x1 = max(0, min(x1, orig_w))
                            y1 = max(0, min(y1, orig_h))
                            x2 = max(0, min(x2, orig_w))
                            y2 = max(0, min(y2, orig_h))
                            
                            detections.append({
                                'bbox': [x1, y1, x2, y2],
                                'center': [x_center_px, y_center_px],
                                'confidence': float(confidence),
                                'class': 'volleyball',  # bestv2 is trained for volleyball
                                'area': (x2 - x1) * (y2 - y1)
                            })
        
        # Apply Non-Maximum Suppression
        detections = self._apply_nms(detections)
        
        return detections
    
    def _apply_nms(self, detections: List[Dict]) -> List[Dict]:
        """Apply Non-Maximum Suppression to remove overlapping detections."""
        if len(detections) <= 1:
            return detections
        
        # Sort by confidence
        detections = sorted(detections, key=lambda x: x['confidence'], reverse=True)
        
        keep = []
        while detections:
            best = detections.pop(0)
            keep.append(best)
            
            # Remove overlapping detections
            detections = [
                det for det in detections 
                if self._calculate_iou(best['bbox'], det['bbox']) < self.nms_threshold
            ]
        
        return keep
    
    def _calculate_iou(self, bbox1: List[int], bbox2: List[int]) -> float:
        """Calculate Intersection over Union between two bounding boxes."""
        x1_1, y1_1, x2_1, y2_1 = bbox1
        x1_2, y1_2, x2_2, y2_2 = bbox2
        
        # Calculate intersection
        x1_i = max(x1_1, x1_2)
        y1_i = max(y1_1, y1_2)
        x2_i = min(x2_1, x2_2)
        y2_i = min(y2_1, y2_2)
        
        if x2_i <= x1_i or y2_i <= y1_i:
            return 0.0
        
        intersection = (x2_i - x1_i) * (y2_i - y1_i)
        
        # Calculate union
        area1 = (x2_1 - x1_1) * (y2_1 - y1_1)
        area2 = (x2_2 - x1_2) * (y2_2 - y1_2)
        union = area1 + area2 - intersection
        
        return intersection / union if union > 0 else 0.0
    
    def get_model_info(self) -> Dict[str, Any]:
        """Get detailed model information."""
        return {
            'model_path': self.model_path,
            'input_shape': self.input_shape,
            'input_size': self.input_size,
            'confidence_threshold': self.confidence_threshold,
            'nms_threshold': self.nms_threshold,
            'output_spec': self.output_spec
        }


def test_detector():
    """Test the detector with a simple frame."""
    print("🧪 Testing BestV2Detector...")
    
    detector = BestV2Detector()
    
    # Create test frame
    test_frame = np.zeros((720, 1280, 3), dtype=np.uint8)
    test_frame[300:400, 600:700] = [255, 255, 255]  # White square
    
    detections = detector.detect_volleyball(test_frame)
    
    print(f"✅ Detector test complete. Found {len(detections)} detections.")
    for i, det in enumerate(detections):
        print(f"   Detection {i+1}: confidence={det['confidence']:.3f}, bbox={det['bbox']}")
    
    return detector


if __name__ == "__main__":
    test_detector()