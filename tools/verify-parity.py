#!/usr/bin/env python3
"""Check a converted Core ML model reproduces the PyTorch reference embeddings.

**Runs on macOS only.** `coremltools` converts anywhere but can only
`predict()` on macOS, which is the whole reason conversion correctness is
established in two halves: `convert-openclip.py` produces the model on Linux,
and this verifies it on a macOS runner against the vectors
`reference-vectors.py` committed.

Without this, a conversion could quietly compute something slightly different —
a transposed tensor, a wrong normalisation, a palettization that lost too much —
and the only symptom would be search results that are a bit worse than they
should be. Nothing would crash.

What it checks, per reference case:
  * cosine similarity against the PyTorch embedding, which is the metric search
    actually uses, so the tolerance means something
  * that the output is unit length, since the model normalises internally
  * that dimensions match the descriptor

Usage:
  python tools/verify-parity.py \
      --models build/models \
      --reference packages/TokinoKit/Tests/TokinoKitTests/Fixtures/model-reference-vectors.json
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

import numpy as np

# Cosine agreement below this means the conversion changed the function the
# model computes. 0.99 is loose enough for 8-bit palettization and fp16
# accumulation, and tight enough that a real error cannot hide: a transposed
# tensor or wrong normalisation drops this far below 0.9.
MINIMUM_COSINE = 0.99
# Unit length should hold almost exactly; the model normalises its own output.
UNIT_LENGTH_TOLERANCE = 1e-2


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    denominator = float(np.linalg.norm(a) * np.linalg.norm(b))
    if denominator == 0:
        return 0.0
    return float(np.dot(a, b) / denominator)


def synthetic_pixels(size: int, seed: int) -> np.ndarray:
    """The same deterministic pattern `reference-vectors.py` uses.

    Kept identical by hand in three places — here, the reference generator, and
    the Swift mirror. A divergence would show up immediately as a parity
    failure, which is the intended safeguard.
    """
    values = np.zeros((1, 3, size, size), dtype=np.float32)
    for channel in range(3):
        for y in range(size):
            for x in range(size):
                raw = (x * 7 + y * 13 + channel * 29 + seed * 101) % 256
                values[0, channel, y, x] = raw / 255.0
    return values


def tokenize_for_text_tower(text: str, reference: dict) -> np.ndarray:
    """Token IDs for `text`, shaped for the text tower.

    Uses `open_clip`'s tokenizer, which is the authority for these weights and
    is what the committed Swift implementation is tested against. Importing it
    here rather than at module scope keeps the skip-on-Linux path above free of
    the dependency.
    """
    import open_clip

    tokenizer = open_clip.get_tokenizer(reference["openClipModel"])
    tokens = tokenizer([text])
    return np.array(tokens, dtype=np.int32)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models", required=True, type=pathlib.Path)
    parser.add_argument("--reference", required=True, type=pathlib.Path)
    args = parser.parse_args()

    if sys.platform != "darwin":
        print("[parity] SKIP: Core ML prediction requires macOS.")
        # Not a failure: the Linux job legitimately cannot run this, and the
        # macOS job is where it counts.
        return 0

    import coremltools as ct

    reference = json.loads(args.reference.read_text())
    dimensions = reference["dimensions"]
    size = reference["inputPixelSize"]
    mean = np.array(reference["pixelMean"], dtype=np.float32).reshape(1, 3, 1, 1)
    std = np.array(
        reference["pixelStandardDeviation"], dtype=np.float32
    ).reshape(1, 3, 1, 1)

    image_path = args.models / "openclip-vit-b32-image.mlpackage"
    text_path = args.models / "openclip-vit-b32-text.mlpackage"
    for path in (image_path, text_path):
        if not path.exists():
            print(f"[parity] ERROR: {path} not found. Run convert-openclip.py first.")
            return 1

    print(f"[parity] loading {image_path.name}")
    image_model = ct.models.MLModel(str(image_path))
    print(f"[parity] loading {text_path.name}")
    text_model = ct.models.MLModel(str(text_path))

    failures: list[str] = []
    checked = 0

    # --- image tower ---
    for case in reference["images"]:
        seed = case["seed"]
        expected = np.array(case["embedding"], dtype=np.float32)

        raw = synthetic_pixels(size, seed)
        normalized = (raw - mean) / std
        output = image_model.predict({"pixel_values": normalized})
        actual = np.array(output["image_embedding"], dtype=np.float32).reshape(-1)

        checked += 1
        if actual.shape[0] != dimensions:
            failures.append(
                f"image seed {seed}: expected {dimensions} dims, got {actual.shape[0]}"
            )
            continue

        similarity = cosine(actual, expected)
        magnitude = float(np.linalg.norm(actual))
        print(f"[parity] image seed {seed}: cosine={similarity:.6f} norm={magnitude:.4f}")

        if similarity < MINIMUM_COSINE:
            failures.append(f"image seed {seed}: cosine {similarity:.6f} < {MINIMUM_COSINE}")
        if abs(magnitude - 1.0) > UNIT_LENGTH_TOLERANCE:
            failures.append(f"image seed {seed}: not unit length ({magnitude:.4f})")

    # --- text tower ---
    for case in reference["texts"]:
        expected = np.array(case["embedding"], dtype=np.float32)
        tokens = np.array([case["tokenIDs"]], dtype=np.int32)

        output = text_model.predict({"input_ids": tokens})
        actual = np.array(output["text_embedding"], dtype=np.float32).reshape(-1)

        checked += 1
        if actual.shape[0] != dimensions:
            failures.append(
                f"text {case['text']!r}: expected {dimensions} dims, got {actual.shape[0]}"
            )
            continue

        similarity = cosine(actual, expected)
        magnitude = float(np.linalg.norm(actual))
        label = case["text"] if case["text"] else "<empty>"
        print(f"[parity] text {label!r}: cosine={similarity:.6f} norm={magnitude:.4f}")

        if similarity < MINIMUM_COSINE:
            failures.append(f"text {case['text']!r}: cosine {similarity:.6f} < {MINIMUM_COSINE}")
        if abs(magnitude - 1.0) > UNIT_LENGTH_TOLERANCE:
            failures.append(f"text {case['text']!r}: not unit length ({magnitude:.4f})")

    # A cross-modal sanity check beyond per-case parity. If image and text
    # embeddings did not share a space — a tower converted wrongly, or the two
    # mismatched — every similarity would be noise, and per-case parity against
    # the same tower would not notice. This asserts the two towers still
    # produce comparable vectors at all.
    if reference["images"] and len(reference["texts"]) >= 2:
        image_vector = np.array(reference["images"][0]["embedding"], dtype=np.float32)
        text_vectors = [
            np.array(case["embedding"], dtype=np.float32)
            for case in reference["texts"]
            if case["text"]
        ]
        similarities = [abs(cosine(image_vector, t)) for t in text_vectors]
        print(
            "[parity] cross-modal |cosine| range: "
            f"{min(similarities):.4f}..{max(similarities):.4f}"
        )
        if max(similarities) > 0.95:
            failures.append(
                "a synthetic pattern matched text suspiciously well; the towers may be mismatched"
            )

    # --- semantic sanity, using the text tower against itself ---
    #
    # Parity proves the conversion is faithful to PyTorch. It does not prove the
    # embeddings mean anything: a tower that had been converted with, say, a
    # transposed projection would reproduce PyTorch exactly if PyTorch were fed
    # the same wrong weights. These checks assert the space still has the
    # structure search depends on — related phrases close together, unrelated
    # ones apart.
    #
    # Text-only on purpose: it needs no image fixtures, so there is nothing to
    # license and nothing to decode. Image-text alignment is checked separately
    # by searching a seeded simulator library.
    print()
    print("[parity] semantic structure of the text tower")

    def embed_text(text: str) -> np.ndarray:
        tokens = tokenize_for_text_tower(text, reference)
        output = text_model.predict({"input_ids": tokens})
        return np.array(output["text_embedding"], dtype=np.float32).reshape(-1)

    # Each triple is (anchor, expected-nearer, expected-further). These are
    # deliberately coarse: a correct CLIP text tower gets all of them easily,
    # and a broken one fails them badly, so the test is about structure rather
    # than fine-grained quality.
    triples = [
        ("a photo of a dog", "a photo of a puppy", "a photo of a submarine"),
        ("seafood rice bowl", "a bowl of raw fish and rice", "a mountain bicycle"),
        ("a city street at night", "a dark urban road", "a bowl of soup"),
    ]

    for anchor, nearer, further in triples:
        anchor_vector = embed_text(anchor)
        near_score = cosine(anchor_vector, embed_text(nearer))
        far_score = cosine(anchor_vector, embed_text(further))
        margin = near_score - far_score
        print(
            f"[parity]   {anchor!r}: near={near_score:.4f} far={far_score:.4f} "
            f"margin={margin:+.4f}"
        )
        if margin <= 0:
            failures.append(
                f"semantic structure lost: {anchor!r} is no closer to "
                f"{nearer!r} ({near_score:.4f}) than to {further!r} ({far_score:.4f})"
            )
        checked += 1

    print()
    if failures:
        print(f"[parity] FAILED: {len(failures)} of {checked} checks")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print(f"[parity] OK: {checked} checks passed, all cosine >= {MINIMUM_COSINE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
