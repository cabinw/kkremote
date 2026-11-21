"""Signal the output order of the controlled single-reference VideoToolbox stream."""


def unsigned_golomb(value):
    binary = f"{value + 1:b}"
    return "0" * (len(binary) - 1) + binary


def display_order_sps(nal):
    # The test encoder emits progressive H.264 Baseline without B pictures.
    # Preserve unfamiliar formats, including a pre-existing VUI.
    if len(nal) < 5 or nal[0] & 31 != 7:
        return nal
    raw = bytearray()
    zeros = 0
    for byte in nal[1:]:
        if zeros >= 2 and byte == 3:
            zeros = 0
            continue
        raw.append(byte)
        zeros = zeros + 1 if byte == 0 else 0
    bits = "".join(f"{b:08b}" for b in raw)
    index = 24  # profile, constraint flags, level

    def bit():
        nonlocal index
        index += 1
        return bits[index - 1] == "1"

    def ue():
        nonlocal index
        width = 0
        while not bit():
            width += 1
        index += width
        return int(bits[index - width - 1:index], 2) - 1

    if raw[0] != 66:
        return nal
    ue()  # seq_parameter_set_id
    ue()  # log2_max_frame_num_minus4
    poc = ue()
    if poc == 0:
        ue()
    elif poc != 2:
        return nal
    if ue() != 1:
        return nal
    bit()  # gaps_in_frame_num_value_allowed_flag
    ue()
    ue()  # picture width and height
    if not bit():  # frame_mbs_only_flag
        return nal
    bit()  # direct_8x8_inference_flag
    if bit():
        for _ in range(4):
            ue()
    vui = index
    if bit() or bits[index:].rstrip("0") != "1":
        return nal
    # VUI present, eight optional fields absent, restrictions present, MV over boundaries allowed.
    restriction = "".join(unsigned_golomb(n) for n in (0, 0, 16, 16, 0, 1))
    result = bits[:vui] + "1" + "0" * 8 + "11" + restriction + "1"
    result += "0" * (-len(result) % 8)
    escaped = bytearray([nal[0]])
    zeros = 0
    for i in range(0, len(result), 8):
        byte = int(result[i:i + 8], 2)
        if zeros == 2 and byte <= 3:
            escaped.append(3)
            zeros = 0
        escaped.append(byte)
        zeros = zeros + 1 if byte == 0 else 0
    return bytes(escaped)


def signal_display_order(packet):
    offset = 0
    output = bytearray()
    while offset + 4 <= len(packet):
        size = int.from_bytes(packet[offset:offset + 4], "big")
        offset += 4
        if not 0 < size <= len(packet) - offset:
            raise ValueError("invalid AVC unit size")
        unit = packet[offset:offset + size]
        if unit[0] & 31 == 7:
            unit = display_order_sps(unit)
        output.extend(len(unit).to_bytes(4, "big"))
        output.extend(unit)
        offset += size
    if offset != len(packet):
        raise ValueError("truncated AVC packet")
    return output
