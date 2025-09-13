"""
ML Model Integration Module

Integrates the actual bestv2.mlpackage model from the BumpSetCut iOS app
into the Python sandbox for accurate testing.
"""

import os
import sys
from typing import Optional, Tuple, List
import json


try:
    import coremltools as ct
    import numpy as np
    COREML_AVAILABLE = True
except ImportError:
    COREML_AVAILABLE = False
    print("❌ CoreML Tools not available - required for ML functionality")
    print("   Install with: pip install coremltools")
    import sys
    sys.exit(1)


class MLModelTracker:
    """
    Real ML model integration for volleyball tracking.
    Uses the actual bestv2.mlpackage model from the iOS app.
    """
    
    def __init__(self, model_path: Optional[str] = None):
        self.model = None
        self.model_path = model_path
        self.input_shape = None
        self.output_names = None
        
        if not COREML_AVAILABLE:
            raise RuntimeError("❌ CoreML Tools not available - cannot proceed without ML model")
        self.load_model()
    
    def load_model(self):
        """Load the bestv2.mlpackage model."""
        if not self.model_path:
            # Try to find the model in the iOS app bundle
            possible_paths = [
                "../BumpSetCut/Resources/ML/bestv2.mlpackage",
                "../../BumpSetCut/Resources/ML/bestv2.mlpackage",
                "../../../BumpSetCut/Resources/ML/bestv2.mlpackage"
            ]
            
            for path in possible_paths:
                full_path = os.path.abspath(os.path.join(os.path.dirname(__file__), path))
                if os.path.exists(full_path):
                    self.model_path = full_path
                    break
        
        if not self.model_path or not os.path.exists(self.model_path):
            print(f"❌ Could not find bestv2.mlpackage model")
            print("   Searched paths:")
            for path in possible_paths:
                full_path = os.path.abspath(os.path.join(os.path.dirname(__file__), path))
                print(f"     {full_path}")
            raise FileNotFoundError("❌ Could not find bestv2.mlpackage model - ML model is required")
        
        try:
            print(f"📦 Loading ML model from: {self.model_path}")
            self.model = ct.models.MLModel(self.model_path)
            
            # Get model metadata
            spec = self.model.get_spec()
            
            # Extract input/output information
            if hasattr(spec, 'neuralNetwork') and spec.neuralNetwork:
                # Neural network model
                inputs = spec.description.input
                outputs = spec.description.output
                
                if inputs:
                    input_desc = inputs[0]
                    if hasattr(input_desc.type, 'imageType'):
                        img_type = input_desc.type.imageType
                        self.input_shape = (img_type.height, img_type.width, 3)
                    elif hasattr(input_desc.type, 'multiArrayType'):
                        array_type = input_desc.type.multiArrayType
                        self.input_shape = tuple(array_type.shape)
                
                self.output_names = [output.name for output in outputs]
            
            print(f"✅ Model loaded successfully")
            print(f"   Input shape: {self.input_shape}")
            print(f"   Output names: {self.output_names}")
            
        except Exception as e:
            print(f"❌ Failed to load ML model: {e}")
            raise RuntimeError(f"Failed to load ML model: {e}")
    
    def track_ball_ml(self, frame: np.ndarray) -> Optional[Tuple[float, float, float]]:
        """
        Track ball using the real ML model.
        
        Args:
            frame: Input video frame as numpy array (H, W, C)
            
        Returns:
            Tuple of (x, y, confidence) if ball detected, None otherwise
        """
        if self.model is None:
            raise RuntimeError("❌ ML model not loaded - cannot perform inference")
        
        try:
            # Preprocess frame for model
            processed_frame = self._preprocess_frame(frame)
            
            # Run inference
            predictions = self.model.predict({'image': processed_frame})
            
            # Debug: Print raw predictions occasionally
            if hasattr(self, '_debug_frame_count'):
                self._debug_frame_count += 1
            else:
                self._debug_frame_count = 1
            
            # Print debug info every 50 frames to avoid spam
            if self._debug_frame_count % 50 == 1:
                print(f"🔍 Frame {self._debug_frame_count} ML Debug:")
                print(f"   Prediction keys: {list(predictions.keys())}")
                for key, value in predictions.items():
                    if hasattr(value, 'shape'):
                        print(f"   {key}: shape={value.shape}, type={type(value)}")
                        if key == 'confidence' and hasattr(value, 'max'):
                            print(f"   {key}: max={value.max():.3f}, min={value.min():.3f}")
            
            # Post-process predictions
            detection = self._postprocess_predictions(predictions, frame.shape)
            
            # Debug: Print detection results
            if detection:
                x, y, confidence = detection
                print(f"🎾 Frame {self._debug_frame_count}: Ball detected at ({x:.1f}, {y:.1f}) conf={confidence:.3f}")
            elif self._debug_frame_count % 100 == 1:  # Print "no detection" less frequently
                print(f"🔍 Frame {self._debug_frame_count}: No ball detected")
            
            return detection
            
        except Exception as e:
            print(f"⚠️  ML inference failed: {e}")
            return None
    
    def _preprocess_frame(self, frame: np.ndarray):
        """
        Preprocess frame for ML model input - convert to PIL Image.
        """
        # Convert OpenCV frame (BGR) to PIL Image (RGB)
        import cv2
        from PIL import Image
        
        # Get target size from model
        if self.input_shape:
            target_height, target_width = self.input_shape[:2]
        else:
            # Default YOLO input size
            target_height, target_width = 640, 640
        
        # Resize frame
        resized = cv2.resize(frame, (target_width, target_height))
        
        # Convert BGR to RGB
        rgb_frame = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB)
        
        # Convert numpy array to PIL Image
        pil_image = Image.fromarray(rgb_frame)
        
        return pil_image
    
    def _postprocess_predictions(self, predictions: dict, original_shape: tuple) -> Optional[Tuple[float, float, float]]:
        """
        Post-process ML model predictions to extract ball detection.
        """
        # This depends on the specific output format of bestv2.mlpackage
        # Common YOLO outputs: coordinates, confidence, class probabilities
        
        best_detection = None
        best_confidence = 0.0
        total_detections = 0
        confidence_threshold = 0.3
        
        # Debug: Print raw prediction analysis every 50 frames
        debug_this_frame = hasattr(self, '_debug_frame_count') and self._debug_frame_count % 50 == 1
        
        # Handle bestv2.mlpackage format: separate coordinates and confidence arrays
        if 'coordinates' in predictions and 'confidence' in predictions:
            coordinates = predictions['coordinates']  # Shape: (N, 4)
            confidences = predictions['confidence']   # Shape: (N, 1)
            
            if debug_this_frame:
                print(f"   Processing bestv2 format:")
                print(f"   coordinates: {coordinates.shape}")  
                print(f"   confidence: {confidences.shape}")
            
            if len(coordinates) > 0 and len(confidences) > 0:
                total_detections = len(coordinates)
                high_conf_count = 0
                
                for i in range(len(coordinates)):
                    if i < len(confidences):
                        x_center, y_center, width, height = coordinates[i]
                        confidence = float(confidences[i][0])  # Extract confidence from (N,1) array
                        
                        if confidence > confidence_threshold:
                            high_conf_count += 1
                            
                            if confidence > best_confidence:
                                # Convert to pixel coordinates  
                                orig_height, orig_width = original_shape[:2]
                                pixel_x = x_center * orig_width
                                pixel_y = y_center * orig_height
                                
                                best_detection = (pixel_x, pixel_y, float(confidence))
                                best_confidence = confidence
                
                if debug_this_frame:
                    print(f"   bestv2: {total_detections} total detections")
                    print(f"   bestv2: {high_conf_count} above confidence threshold ({confidence_threshold})")
                    if len(confidences) > 0:
                        max_conf = float(confidences.max())
                        print(f"   bestv2: max confidence = {max_conf:.3f}")
        
        # Fallback: Handle other YOLO formats
        else:
            for key, value in predictions.items():
                if isinstance(value, np.ndarray):
                    if debug_this_frame:
                        print(f"   Processing {key}: {value.shape}")
                    
                    # Assume YOLO-style output: [x, y, w, h, confidence, class_probs...]
                    if value.ndim >= 2 and value.shape[-1] >= 5:
                        detections_in_output = value.reshape(-1, value.shape[-1])
                        total_detections += len(detections_in_output)
                        
                        high_conf_count = 0
                        for detection in detections_in_output:
                            if len(detection) >= 5:
                                x_center, y_center, width, height, confidence = detection[:5]
                                
                                if confidence > confidence_threshold:
                                    high_conf_count += 1
                                
                                # Filter by confidence threshold
                                if confidence > confidence_threshold and confidence > best_confidence:
                                    # Convert to pixel coordinates
                                    orig_height, orig_width = original_shape[:2]
                                    pixel_x = x_center * orig_width
                                    pixel_y = y_center * orig_height
                                    
                                    best_detection = (pixel_x, pixel_y, float(confidence))
                                    best_confidence = confidence
                        
                        if debug_this_frame:
                            print(f"   {key}: {len(detections_in_output)} total detections")
                            print(f"   {key}: {high_conf_count} above confidence threshold ({confidence_threshold})")
                            if high_conf_count > 0:
                                max_conf = max(detection[4] for detection in detections_in_output)
                                print(f"   {key}: max confidence = {max_conf:.3f}")
                            elif len(detections_in_output) > 0:
                                max_conf = max(detection[4] for detection in detections_in_output)
                                print(f"   {key}: max confidence = {max_conf:.3f} (below threshold)")
        
        if debug_this_frame and total_detections > 0:
            if best_detection:
                print(f"   ✅ Best detection: conf={best_confidence:.3f}")
            else:
                print(f"   ❌ No detections above threshold ({confidence_threshold})")
        
        return best_detection
    


def setup_ml_model() -> MLModelTracker:
    """
    Set up and return the ML model tracker.
    """
    return MLModelTracker()


def validate_ml_installation() -> dict:
    """
    Validate ML model installation and requirements.
    """
    status = {
        'coreml_available': COREML_AVAILABLE,
        'model_found': False,
        'model_path': None,
        'requirements_met': False
    }
    
    if COREML_AVAILABLE:
        tracker = MLModelTracker()
        status['model_found'] = tracker.model is not None
        status['model_path'] = tracker.model_path
        status['requirements_met'] = tracker.model is not None
    
    return status


def print_ml_status():
    """
    Print ML model integration status.
    """
    status = validate_ml_installation()
    
    print("🤖 ML Model Integration Status:")
    print(f"   CoreML Tools: {'✅ Available' if status['coreml_available'] else '❌ Not installed'}")
    print(f"   bestv2.mlpackage: {'✅ Found' if status['model_found'] else '❌ Not found'}")
    
    if status['model_path']:
        print(f"   Model path: {status['model_path']}")
    
    if not status['coreml_available']:
        print("\n📦 To use the real ML model, install CoreML Tools:")
        print("   pip install coremltools")
    
    if not status['model_found']:
        print("\n📁 Make sure the bestv2.mlpackage model is accessible")
        print("   The sandbox looks for it relative to the iOS app bundle")
    
    return status['requirements_met']