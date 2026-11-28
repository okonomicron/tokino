"""Reference token IDs from Hugging Face's CLIPTokenizerFast.

A second, independently-implemented reference. Only cases where both agree
become strict Swift test vectors; disagreements are recorded and resolved in
favour of open_clip, which trained these weights.
"""
import json
import os
import sys

OUT = sys.argv[1]
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from transformers import CLIPTokenizerFast  # noqa: E402

from tokenizer_cases import CASES  # noqa: E402

tok = CLIPTokenizerFast.from_pretrained("laion/CLIP-ViT-B-32-laion2B-s34B-b79K")
payload = {
    "implementation": "transformers.CLIPTokenizerFast",
    "cases": [
        {"text": t, "ids": tok(t, add_special_tokens=False)["input_ids"]} for t in CASES
    ],
}
with open(OUT, "w") as handle:
    json.dump(payload, handle, indent=1, ensure_ascii=False)
print(f"hf: {len(payload['cases'])} cases")
