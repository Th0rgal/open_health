"""Pure feature mappings shared by the activity runner and its backtests."""


def unpack_real_step(raw_feature_1: bytes, raw_feature_2: bytes) -> list[int]:
    """Expand the ring's two 14-byte real-step packets to the decoder's 27 ints."""
    p1, p2 = raw_feature_1, raw_feature_2
    if len(p1) != 14 or len(p2) != 14:
        raise ValueError("real-step feature packets must both be 14 bytes")
    carry = p2[13]
    return [
        (p2[10] << 2) | (carry & 0x3), p2[11], p2[12],
        (p1[0] << 1) | (p1[3] >> 7), (p1[1] << 1) | ((carry >> 7) & 1),
        (p1[2] << 1) | ((carry >> 6) & 1), p1[3] & 0x7F, p1[4], p1[5], p1[6], p1[7],
        (p1[8] << 1) | (p1[11] >> 7), (p1[9] << 1) | ((carry >> 5) & 1),
        (p1[10] << 1) | ((carry >> 4) & 1), p1[11] & 0x7F, p1[12], p1[13], p2[0], p2[1],
        (p2[2] << 1) | (p2[5] >> 7), (p2[3] << 1) | ((carry >> 3) & 1),
        (p2[4] << 1) | ((carry >> 2) & 1), p2[5] & 0x7F, p2[6], p2[7], p2[8], p2[9],
    ]


def decoder_to_aad(row: list[float]) -> list[float]:
    """Match Android's px.b -> AadPyTorchModel step-motion column order."""
    if len(row) != 11:
        raise ValueError("step-motion decoder row must have 11 values")
    # decoder: sum, y, z, total, strideFreq, strideAmp, firstFreq,
    #          firstAmp, gaitAmp, highFrac, midFrac
    # AAD:     firstFreq, firstAmp, highFrac, midFrac, gaitAmp,
    #          strideAmp, strideFreq, sum, total, y, z
    return [row[i] for i in (6, 7, 9, 10, 8, 5, 4, 0, 3, 1, 2)]
