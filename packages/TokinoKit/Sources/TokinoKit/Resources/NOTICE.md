# Third-party assets

## CLIP BPE tokenizer vocabulary and merges

`clip-vocab.json` and `clip-merges.txt` are redistributed from
[`laion/CLIP-ViT-B-32-laion2B-s34B-b79K`](https://huggingface.co/laion/CLIP-ViT-B-32-laion2B-s34B-b79K),
which is published under the **MIT License**. MIT requires that the copyright
notice and permission notice accompany redistributed copies, which is what this
file is for.

These are the tokenizer assets only. The model **weights** are not committed to
this repository: they are converted by `tools/convert-openclip.py` and
downloaded by the app at runtime. See `docs/DECISIONS.md`.

The vocabulary is 49,408 tokens. Start-of-text is 49406 and end-of-text is
49407, matching `open_clip`'s procedurally-built vocabulary even though the two
use different spellings for those tokens' names.

```
MIT License

Copyright (c) 2022 LAION

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## open_clip reference tokenizer

`tools/assets/openclip_tokenizer.py` is a vendored copy of `open_clip`'s
tokenizer, used **only** to generate reference token IDs for tests. It is not
shipped in the app. `open_clip` is MIT-licensed
(https://github.com/mlfoundations/open_clip).
