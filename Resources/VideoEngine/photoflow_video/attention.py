"""Memory-bounded attention.

PyTorch's MPS backend materialises the full attention matrix and is known to return wrong
results once a single attention matrix exceeds ~2^31 elements (pytorch issue: MPS SDPA with very
large sequence lengths). Video transformers reach that quickly (81 frames at 480p = 32,760 tokens).
This wrapper splits the query sequence into chunks so that every chunk's score matrix stays far
below that limit and below a configurable memory budget. Results are numerically identical to the
unchunked call (softmax is per query row)."""
import math

import torch
import torch.nn.functional as F

_original_sdpa = F.scaled_dot_product_attention
# Elements of one chunk's score matrix (batch*heads*q*k). 2^28 ≈ 268M → 0.5 GB in bf16.
MAX_SCORE_ELEMENTS = 1 << 28
stats = {"calls": 0, "chunked_calls": 0, "max_chunks": 1}


def chunked_sdpa(query, key, value, attn_mask=None, dropout_p=0.0, is_causal=False, scale=None, **kwargs):
    stats["calls"] += 1
    if query.dim() != 4 or is_causal:
        return _original_sdpa(query, key, value, attn_mask=attn_mask, dropout_p=dropout_p,
                              is_causal=is_causal, scale=scale, **kwargs)
    b, h, lq, _ = query.shape
    lk = key.shape[-2]
    total = b * h * lq * lk
    if total <= MAX_SCORE_ELEMENTS:
        return _original_sdpa(query, key, value, attn_mask=attn_mask, dropout_p=dropout_p,
                              is_causal=False, scale=scale, **kwargs)
    rows = max(1, MAX_SCORE_ELEMENTS // (b * h * lk))
    chunks = math.ceil(lq / rows)
    stats["chunked_calls"] += 1
    stats["max_chunks"] = max(stats["max_chunks"], chunks)
    out = torch.empty(query.shape[:-1] + (value.shape[-1],), dtype=query.dtype, device=query.device)
    for i in range(0, lq, rows):
        m = None
        if attn_mask is not None:
            m = attn_mask[..., i:i + rows, :] if attn_mask.shape[-2] == lq else attn_mask
        out[:, :, i:i + rows] = _original_sdpa(query[:, :, i:i + rows], key, value, attn_mask=m,
                                               dropout_p=dropout_p, is_causal=False, scale=scale, **kwargs)
    return out


def install():
    """Replace torch's SDPA before diffusers is imported (diffusers' native backend calls it)."""
    F.scaled_dot_product_attention = chunked_sdpa
    torch.nn.functional.scaled_dot_product_attention = chunked_sdpa
