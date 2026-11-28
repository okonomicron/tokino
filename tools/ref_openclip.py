"""Reference token IDs from open_clip's SimpleTokenizer.

This is the authoritative tokenizer for the LAION OpenCLIP weights, because the
model was trained with it. Run in its own process: it needs a torch stub, which
upsets transformers' import probe if both live in one interpreter.
"""
import gzip
import json
import os
import sys
import types

ASSETS = sys.argv[1]
OUT = sys.argv[2]

# open_clip imports torch only to build tensors in __call__; the encode() path
# does not need it, so a stub avoids a multi-gigabyte dependency.
stub = types.ModuleType("torch")
stub.Tensor = object
stub.long = int
stub.LongTensor = object
sys.modules["torch"] = stub

# SimpleTokenizer builds its vocab procedurally from a gzipped merges file and
# instantiates one at import time, so the file must exist before the import.
bpe_gz = os.path.join(ASSETS, "bpe_simple_vocab_16e6.txt.gz")
if not os.path.exists(bpe_gz):
    with open(os.path.join(ASSETS, "merges.txt"), "rb") as src, gzip.open(bpe_gz, "wb") as dst:
        dst.write(src.read())

sys.path.insert(0, ASSETS)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Imported here, after the stub and the vocabulary file above, because
# open_clip builds a tokenizer at import time from a file that must exist.
import openclip_tokenizer as oct  # noqa: E402
from tokenizer_cases import CASES  # noqa: E402

tok = oct.SimpleTokenizer(bpe_path=bpe_gz)
payload = {
    "implementation": "open_clip.SimpleTokenizer",
    "sot_token_id": tok.sot_token_id,
    "eot_token_id": tok.eot_token_id,
    "vocab_size": tok.vocab_size,
    "context_length": tok.context_length,
    "cases": [{"text": t, "ids": tok.encode(t)} for t in CASES],
}
with open(OUT, "w") as handle:
    json.dump(payload, handle, indent=1, ensure_ascii=False)
print(f"open_clip: {len(payload['cases'])} cases, sot={tok.sot_token_id}, eot={tok.eot_token_id}")
