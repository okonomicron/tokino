#!/usr/bin/env python3
"""Convert OpenCLIP ViT-B/32 to Core ML, for on-device photo search.

Runs on Linux. `coremltools` supports conversion anywhere; only `predict()`
needs macOS, which is why parity is verified separately on a macOS CI runner
against the reference vectors `reference-vectors.py` writes.

Why this model: Apple's MobileCLIP would be the obvious choice and cannot be
used, because its weights are licensed for research only — the terms exclude
"commercial exploitation, product development or use in any commercial product
or service". These LAION weights are MIT. SigLIP 2 scores better but its text
tower is 539 MB against this model's ~120 MB, because its vocabulary is 256k
tokens rather than 49,408; keeping search working offline won out. See
docs/DECISIONS.md.

The two towers are converted separately because they run at different times:
the image tower runs once per photo during indexing, the text tower once per
search query. Separate packages mean the app can load only what it needs.

Outputs, into --output-dir:
  openclip-vit-b32-image.mlpackage
  openclip-vit-b32-text.mlpackage
  openclip-vit-b32-image.mlpackage.zip   (+ .zip for distribution)
  openclip-vit-b32-text.mlpackage.zip
  manifest.json                          (dims, checksums, licence, provenance)

Usage:
  python tools/convert-openclip.py --output-dir build/models
  python tools/convert-openclip.py --output-dir build/models --precision fp16
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import shutil
import sys
import zipfile

import coremltools as ct
import torch

MODEL_NAME = "ViT-B-32"
PRETRAINED = "laion2b_s34b_b79k"
MODEL_IDENTIFIER = "openclip-vit-b32-laion2b-v1"
WEIGHTS_SOURCE = "https://huggingface.co/laion/CLIP-ViT-B-32-laion2B-s34B-b79K"
WEIGHTS_LICENSE = "MIT"

# The text tower's fixed sequence length. CLIP is not variable-length: the
# tower reads exactly this many tokens, padded with zeros.
CONTEXT_LENGTH = 77


def _log(message: str) -> None:
    print(f"[convert] {message}", flush=True)


def build_torch_model():
    """Loads the OpenCLIP model and its preprocessing constants."""
    import open_clip

    _log(f"loading {MODEL_NAME} / {PRETRAINED}")
    model, _, preprocess = open_clip.create_model_and_transforms(
        MODEL_NAME, pretrained=PRETRAINED
    )
    model.eval()

    # Read normalisation from the model's own transform rather than hardcoding
    # it. A wrong mean or standard deviation degrades every embedding silently.
    mean = std = None
    for transform in getattr(preprocess, "transforms", []):
        if hasattr(transform, "mean") and hasattr(transform, "std"):
            mean = [float(v) for v in transform.mean]
            std = [float(v) for v in transform.std]
    if mean is None or std is None:
        raise RuntimeError("could not read normalisation constants from the preprocessing chain")

    image_size = model.visual.image_size
    if isinstance(image_size, (tuple, list)):
        image_size = int(image_size[0])
    embed_dim = int(model.text_projection.shape[1])

    _log(f"image size {image_size}, embed dim {embed_dim}")
    _log(f"mean {mean}, std {std}")
    return model, int(image_size), embed_dim, mean, std


def _make_wrappers(model):
    """Wraps each tower so it returns a normalised embedding.

    Normalising inside the model means the app never has to, and more
    importantly means the Swift side cannot forget to. Cosine similarity is
    then just a dot product.
    """

    class ImageEncoder(torch.nn.Module):
        def __init__(self, clip):
            super().__init__()
            self.clip = clip

        def forward(self, pixel_values):
            features = self.clip.encode_image(pixel_values)
            return features / features.norm(dim=-1, keepdim=True)

    class TextEncoder(torch.nn.Module):
        def __init__(self, clip):
            super().__init__()
            self.clip = clip

        def forward(self, input_ids):
            features = self.clip.encode_text(input_ids)
            return features / features.norm(dim=-1, keepdim=True)

    return ImageEncoder(model).eval(), TextEncoder(model).eval()


def convert_tower(wrapper, example_input, input_spec, output_name, precision: str):
    """Traces a tower and converts it to a Core ML package."""
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example_input)

    compute_precision = (
        ct.precision.FLOAT16 if precision == "fp16" else ct.precision.FLOAT32
    )

    return ct.convert(
        traced,
        inputs=[input_spec],
        outputs=[ct.TensorType(name=output_name)],
        convert_to="mlprogram",
        compute_precision=compute_precision,
        # iOS 18 is the package's floor; the app targets iOS 26 but the model
        # need not be that restrictive.
        minimum_deployment_target=ct.target.iOS18,
    )


def palettize(model, bits: int):
    """Palettizes weights to shrink the download.

    Both towers together are roughly 300 MB at fp16 and about 150 MB at 8-bit,
    which is the difference between a tolerable first-run download and an
    annoying one. The macOS parity test is what decides whether the accuracy
    cost is acceptable: it asserts cosine agreement against the fp32 reference,
    and this step is reverted if that fails.
    """
    from coremltools.optimize.coreml import (
        OpPalettizerConfig,
        OptimizationConfig,
        palettize_weights,
    )

    _log(f"palettizing weights to {bits}-bit")
    config = OptimizationConfig(
        global_config=OpPalettizerConfig(mode="kmeans", nbits=bits)
    )
    return palettize_weights(model, config)


def sha256_of(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def zip_package(package_dir: pathlib.Path, archive_path: pathlib.Path) -> None:
    """Zips an .mlpackage directory deterministically.

    A fixed timestamp and sorted entries mean the same inputs produce the same
    archive, so the checksum in the manifest is reproducible rather than
    changing on every run.
    """
    if archive_path.exists():
        archive_path.unlink()
    files = sorted(p for p in package_dir.rglob("*") if p.is_file())
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for file in files:
            info = zipfile.ZipInfo(str(file.relative_to(package_dir.parent)))
            info.date_time = (1980, 1, 1, 0, 0, 0)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, file.read_bytes())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True, type=pathlib.Path)
    parser.add_argument(
        "--precision",
        choices=["fp16", "fp32"],
        default="fp16",
        help="Core ML compute precision before palettization.",
    )
    parser.add_argument(
        "--palettize-bits",
        type=int,
        default=8,
        help="Weight palettization bit width; 0 disables it.",
    )
    args = parser.parse_args()

    output_dir: pathlib.Path = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    model, image_size, embed_dim, mean, std = build_torch_model()
    image_encoder, text_encoder = _make_wrappers(model)

    # --- image tower ---
    _log("converting the image tower")
    example_image = torch.zeros(1, 3, image_size, image_size)
    image_mlmodel = convert_tower(
        image_encoder,
        example_image,
        # A plain tensor input, not ct.ImageType: the app normalises pixels with
        # the model's own mean and standard deviation, and keeping that in Swift
        # makes it visible and testable rather than hidden in the model's
        # preprocessing.
        ct.TensorType(name="pixel_values", shape=example_image.shape, dtype=float),
        "image_embedding",
        args.precision,
    )

    # --- text tower ---
    _log("converting the text tower")
    example_tokens = torch.zeros(1, CONTEXT_LENGTH, dtype=torch.int32)
    text_mlmodel = convert_tower(
        text_encoder,
        example_tokens,
        ct.TensorType(name="input_ids", shape=example_tokens.shape, dtype=int),
        "text_embedding",
        args.precision,
    )

    if args.palettize_bits:
        image_mlmodel = palettize(image_mlmodel, args.palettize_bits)
        text_mlmodel = palettize(text_mlmodel, args.palettize_bits)

    artifacts = {}
    for name, mlmodel in (("image", image_mlmodel), ("text", text_mlmodel)):
        package_path = output_dir / f"openclip-vit-b32-{name}.mlpackage"
        if package_path.exists():
            shutil.rmtree(package_path)
        mlmodel.save(str(package_path))

        archive_path = output_dir / f"openclip-vit-b32-{name}.mlpackage.zip"
        zip_package(package_path, archive_path)

        artifacts[name] = {
            "fileName": archive_path.name,
            "sha256": sha256_of(archive_path),
            "byteCount": archive_path.stat().st_size,
        }
        _log(f"{name}: {artifacts[name]['byteCount'] / 1_048_576:.1f} MB")

    manifest = {
        "identifier": MODEL_IDENTIFIER,
        "dimensions": embed_dim,
        "inputPixelSize": image_size,
        "contextLength": CONTEXT_LENGTH,
        "pixelMean": mean,
        "pixelStandardDeviation": std,
        "imageEncoder": artifacts["image"],
        "textEncoder": artifacts["text"],
        "weightsLicense": WEIGHTS_LICENSE,
        "weightsSource": WEIGHTS_SOURCE,
        "conversion": {
            "coremltools": ct.__version__,
            "torch": torch.__version__,
            "precision": args.precision,
            "palettizeBits": args.palettize_bits,
            "openClipModel": MODEL_NAME,
            "openClipPretrained": PRETRAINED,
        },
    }
    manifest_path = output_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    _log(f"wrote {manifest_path}")

    # Sanity checks that would otherwise only surface on the macOS runner, by
    # which point the conversion has already been published.
    if embed_dim != 512:
        _log(f"ERROR: expected 512 dimensions, got {embed_dim}")
        return 1
    if image_size != 224:
        _log(f"ERROR: expected a 224px input, got {image_size}")
        return 1

    _log("done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
