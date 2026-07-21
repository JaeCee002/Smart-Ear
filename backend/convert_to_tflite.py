"""Convert the trained Keras sound classifier to a Flutter-ready TFLite model."""

from pathlib import Path

import tensorflow as tf


ROOT = Path(__file__).resolve().parent
SOURCE_MODEL = ROOT / "model" / "sound_model.h5"
OUTPUT_MODEL = ROOT.parent / "frontend" / "assets" / "models" / "sound_model.tflite"


def main() -> None:
    model = tf.keras.models.load_model(SOURCE_MODEL)
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    tflite_model = converter.convert()

    OUTPUT_MODEL.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_MODEL.write_bytes(tflite_model)
    print(f"Wrote {len(tflite_model):,} bytes to {OUTPUT_MODEL}")


if __name__ == "__main__":
    main()
