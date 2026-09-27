# Test support: load the services from THIS checkout, with stand-ins for the libraries the host
# venv has and a dev box may not (eth_abi, eth_account, eth_utils, lighter).
#
# The stand-ins are installed only when the real module is missing, so on the host the tests run
# against the real libraries. The keccak here is a plain Keccak-256 (the pre-NIST padding that
# Ethereum uses, NOT hashlib.sha3_256); it is checked against published vectors in
# test_signer_stack5.py before anything relies on it.
import importlib.machinery
import importlib.util
import os
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(os.path.dirname(HERE), "bin")
FIX = os.path.join(HERE, "fixtures")

_RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
       0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
       0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
       0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
       0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
       0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
# _ROT[x][y]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_M = (1 << 64) - 1


def _rol(v, n):
    return ((v << n) | (v >> (64 - n))) & _M if n else v


def _f(a):
    for rc in _RC:
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
        a = [[a[x][y] ^ d[x] for y in range(5)] for x in range(5)]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                b[y][(2 * x + 3 * y) % 5] = _rol(a[x][y], _ROT[x][y])
        a = [[b[x][y] ^ (~b[(x + 1) % 5][y] & b[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
        a[0][0] ^= rc
    return a


def keccak256(data):
    rate = 136
    msg = bytearray(data) + b"\x01"
    msg += b"\x00" * (-len(msg) % rate)
    msg[-1] |= 0x80
    a = [[0] * 5 for _ in range(5)]
    for off in range(0, len(msg), rate):
        block = msg[off:off + rate]
        for i in range(rate // 8):
            x, y = i % 5, i // 5
            a[x][y] ^= int.from_bytes(block[8 * i:8 * i + 8], "little")
        a = _f(a)
    out = b""
    for i in range(4):
        out += a[i % 5][i // 5].to_bytes(8, "little")
    return out


def keccak(primitive=None, hexstr=None, text=None):
    if text is not None:
        return keccak256(text.encode())
    if hexstr is not None:
        return keccak256(bytes.fromhex(hexstr[2:] if hexstr.startswith("0x") else hexstr))
    return keccak256(bytes(primitive))


def _word(t, v):
    if t == "address":
        return bytes(12) + bytes.fromhex(v[2:] if isinstance(v, str) else v.hex())
    if t == "bytes32":
        assert len(v) == 32
        return bytes(v)
    if t == "bool":
        return int(bool(v)).to_bytes(32, "big")
    if t.startswith("uint"):
        assert 0 <= v < 1 << int(t[4:] or 256), (t, v)
        return int(v).to_bytes(32, "big")
    if t.startswith("int"):
        return (int(v) % (1 << 256)).to_bytes(32, "big")
    raise NotImplementedError("stub encode: static types only, not %s" % t)


def encode(types_, values):
    return b"".join(_word(t, v) for t, v in zip(types_, values))


def decode(types_, data):
    out = []
    for i, t in enumerate(types_):
        w = int.from_bytes(data[32 * i:32 * i + 32], "big")
        if t.startswith("int"):
            w = w - (1 << 256) if w >= 1 << 255 else w
        elif not t.startswith("uint"):
            raise NotImplementedError("stub decode: ints only, not %s" % t)
        out.append(w)
    return tuple(out)


class _Account:
    @staticmethod
    def from_key(pk):
        raise NotImplementedError("stub Account: tests never derive keys")

    @staticmethod
    def unsafe_sign_hash(digest, pk):
        raise NotImplementedError("stub Account: tests capture digests instead of signing")


def install():
    def need(name):
        try:
            __import__(name)
            return False
        except ImportError:
            return True
    if need("eth_utils"):
        m = types.ModuleType("eth_utils"); m.keccak = keccak; sys.modules["eth_utils"] = m
    if need("eth_abi"):
        m = types.ModuleType("eth_abi"); m.encode = encode; m.decode = decode; sys.modules["eth_abi"] = m
    if need("eth_account"):
        m = types.ModuleType("eth_account"); m.Account = _Account; sys.modules["eth_account"] = m
    sys.modules.setdefault("lighter", types.ModuleType("lighter"))


def load(filename, name):
    """Import deploy/bin/<filename> from this checkout, extension or not."""
    install()
    path = os.path.join(BIN, filename)
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True
    loader.exec_module(mod)
    return mod


def fixture(name):
    import json
    with open(os.path.join(FIX, name)) as f:
        return json.load(f)
