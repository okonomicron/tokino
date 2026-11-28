"""The shared list of tokenizer test cases.

Kept in one place so both reference implementations tokenize exactly the same
inputs, and so the Swift fixture and the Python references cannot drift.

Cases are chosen to cover what actually breaks BPE implementations rather than
to look thorough: case folding, whitespace collapsing, contractions, digits
(open_clip splits them one by one, unlike the original OpenAI CLIP),
punctuation runs, non-ASCII, emoji outside the BMP, HTML entities, the literal
special-token strings, and inputs long enough to force truncation.
"""

CASES: list[str] = [
    # The ordinary path.
    "a photo of a dog",
    "kaisendon",
    "seafood rice bowl, Hokkaido",
    # Case folding: open_clip lowercases by default.
    "A Photo Of A DOG",
    "MiXeD CaSe WiTh 99 numbers",
    # Whitespace handling and collapsing.
    "  leading and   trailing   spaces  ",
    "newline\nand\ttab",
    "",
    "   ",
    # Contractions have dedicated regex alternatives.
    "don't stop",
    "it's a 123 test",
    # Digits: the pattern matches a single digit at a time.
    "1",
    "42",
    "2024",
    "price: $42.50 (50% off)!",
    # Punctuation runs match as one group.
    "hyphen-ated and under_scored",
    "...!!!???",
    # Non-ASCII and multi-byte.
    "café naïve résumé",
    "日本の海鮮丼",
    "emoji sushi",
    # HTML entities: open_clip's cleaner unescapes them.
    "&amp; html entity",
    # The literal special-token text must not become a special token.
    "<|startoftext|> literal",
    # Long enough to exercise truncation at the context length.
    "a" * 200,
    " ".join(["word"] * 100),

    # Unicode normalisation, probed because open_clip runs ftfy.fix_text before
    # tokenizing and the Swift port replicates only the parts that typed input
    # can actually produce. See CLIPTextCleaner's documentation.
    "cafe\u0301",            # decomposed e-acute: NFC must recompose it
    "don\u2019t",            # curly apostrophe: what an iOS keyboard produces
    "\u201cquoted\u201d",    # curly double quotes
    "\uff46\uff55\uff4c\uff4c",  # fullwidth latin
    "\uff11\uff12\uff13",    # fullwidth digits
    "\uff8a\uff9d",          # halfwidth katakana
    "\ufb01sh",              # fi ligature
    "a\u00a0b",              # non-breaking space counts as whitespace
    "\u00bd cup",            # vulgar fraction must NOT be expanded
    "\u2026ellipsis",        # ellipsis must NOT be expanded
    "\u2014dash",            # em dash is left alone
    "&amp;amp; double",     # html.unescape is applied twice
    "\u6d77\u9bae\u4e3c",    # kaisendon in kanji: the acceptance-test term
]
