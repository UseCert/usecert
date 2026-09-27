# Stack-5 cutover kit (deploy/bin/usecert-s5-cutover): the pure parts against recorded and
# generated fixtures, and every subcommand's offline dry run in sequence against the simulator.
# No host, no network, no key; nothing is sent.
# Run: python deploy/tests/test_s5_cutover.py   (unittest)
#
# FIXTURES
#   fixtures/s5-build/          written by the REAL scripts, not by hand: test/script/DeployMainnetStack5.t.sol's
#                               harness ran DeployMainnet (its _writeAddressBook wrote 4663.stack5.json) and
#                               SafeBatches.phaseA() (the Transaction Builder file, the MultiSendCallOnly payload
#                               and the proposals file), at feat/stack5 b8fd1a9. Addresses are the harness's.
#   fixtures/safe-batch1a-registry.hex   the batch-1a data the Safe's owners signed and executed at nonce 2
#                               on 4663; its safeTxHash was computed by the Safe (getTransactionHash).
#   fixtures/orderBookDetails-14-16.json recorded from api.rh.lighter.xyz, 2026-09-27.
import contextlib
import copy
import io
import json
import os
import re
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _ethstub  # noqa: E402

kit = _ethstub.load("usecert-s5-cutover", "s5cutover")
BUILD = os.path.join(_ethstub.FIX, "s5-build")
BOOK = os.path.join(BUILD, "4663.stack5.json")
H_PUBKEY = "0x012258abd09aa219c49c168c88d3fdb0c4f1004757709ae2400824c2ed19534cb4e3e038864c6076"
SAFE = kit.GOVERNANCE_SAFE
OWNERS = ["0x" + ("%02x" % (k + 1)) * 20 for k in range(3)]   # the simulator's owners


def rd(path, mode="r"):
    with open(path, mode) as f:
        return f.read()


def wr(path, data):
    with open(path, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode())


def jload(path):
    return json.loads(rd(path))


def sig(byte, v=27):
    return "0x" + byte * 64 + "%02x" % v


def book():
    return kit.load_book(BOOK, sim=True)


def fixture_build():
    ms = jload(os.path.join(BUILD, "4663.stack5.phaseA.multisend.json"))
    tb = jload(os.path.join(BUILD, "4663.stack5.phaseA.json"))
    prop = jload(os.path.join(BUILD, "4663.stack5.phaseA-proposals.json"))
    return ms, tb, prop


class Hashing(unittest.TestCase):
    def test_keccak_published_vectors(self):
        self.assertEqual(kit.keccak256(b"").hex(), "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        self.assertEqual(kit.keccak256(b"abc").hex(), "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
        self.assertEqual(kit.keccak256(b"x" * 500), _ethstub.keccak256(b"x" * 500))

    def test_every_selector_is_keccak_of_its_signature(self):
        self.assertEqual(set(kit.SEL), set(kit.SIGNATURES))
        for name, s in kit.SIGNATURES.items():
            self.assertEqual(kit.keccak256(s.encode())[:4].hex(), kit.SEL[name], s)

    def test_safe_typehashes_and_event_topic(self):
        self.assertEqual(kit.keccak256(b"EIP712Domain(uint256 chainId,address verifyingContract)").hex(), kit.DOMAIN_TYPEHASH)
        self.assertEqual(kit.keccak256(b"SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,"
                                       b"uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)").hex(),
                         kit.SAFE_TX_TYPEHASH)
        self.assertEqual(kit.hx(kit.keccak256(b"ExecutionSuccess(bytes32,uint256)")), kit.TOPIC_EXECUTION_SUCCESS)

    def test_safe_tx_hash_matches_what_the_safe_executed(self):
        data = rd(os.path.join(_ethstub.FIX, "safe-batch1a-registry.hex")).strip()
        self.assertEqual(kit.safe_tx_hash(SAFE, kit.MULTISEND_141, data, 1, 2),
                         "0x5508040b50151dc632a08830ba9e4906aa6df09516bade9622693f02695d0257")
        # a different nonce is a different transaction
        self.assertNotEqual(kit.safe_tx_hash(SAFE, kit.MULTISEND_141, data, 1, 3),
                            "0x5508040b50151dc632a08830ba9e4906aa6df09516bade9622693f02695d0257")

    def test_checksum(self):
        self.assertEqual(kit.checksum(SAFE.lower()), SAFE)
        self.assertEqual(kit.checksum(kit.MULTISEND_CALLONLY_141.lower()), kit.MULTISEND_CALLONLY_141)


class Minimums(unittest.TestCase):
    ROWS = {int(r["market_id"]): r for r in _ethstub.fixture("orderBookDetails-14-16.json")["order_book_details"]}

    def keeper_setup(self, b):
        # usecert-keeper-setup's own arithmetic, for comparison
        sd = int(b.get("size_decimals", b.get("supported_size_decimals", 4)))
        return round(float(b["min_base_amount"]) * 10 ** sd), int(float(b["min_quote_amount"]) * 1e18)

    def test_recorded_rows(self):
        for m in (14, 16):
            self.assertEqual(kit.venue_minimums(self.ROWS[m], m, 4), (200, 10 * 10 ** 18))
            self.assertEqual(kit.venue_minimums(self.ROWS[m], m, 4), self.keeper_setup(self.ROWS[m]))

    def test_exact_where_float_is_not(self):
        # Decimal, not float: every representable venue row converts exactly.
        for q, want in (("0.29", 29 * 10 ** 16), ("10.100001", 10_100_001 * 10 ** 12), ("999.999999", 999_999_999 * 10 ** 12)):
            self.assertEqual(kit.venue_minimums(dict(self.ROWS[16], min_quote_amount=q), 16, 4)[1], want)

    def test_refusals(self):
        r = self.ROWS[16]
        for bad, args in (
            (r, (14, 4)),                                                   # another market's row
            (r, (16, 2)),                                                   # book's units differ
            (dict(r, status="frozen"), (16, 4)),
            (dict(r, min_base_amount="0.00005"), (16, 4)),                 # finer than 1e-4
            (dict(r, min_base_amount="0"), (16, 4)),
            (dict(r, min_quote_amount="1000.5"), (16, 4)),                 # CertVault's $1,000 bound
        ):
            with self.assertRaises(kit.Refuse):
                kit.venue_minimums(bad, *args)


class MultiSend(unittest.TestCase):
    def test_round_trip_is_byte_exact_with_forge(self):
        ms, tb, _ = fixture_build()
        e = kit.multisend_entries(ms["data"])
        self.assertEqual(len(e), 48)
        self.assertEqual([(t["to"].lower(), t["data"]) for t in tb["transactions"]], [(to, kit.hx(cd)) for _, to, _, cd in e])
        self.assertEqual(kit.multisend_encode(e), ms["data"])
        self.assertEqual(kit.split_multisend(ms["data"]), [ms["data"]])

    def big(self, copies):
        ms, _, _ = fixture_build()
        return kit.multisend_encode(kit.multisend_entries(ms["data"]) * copies)

    def test_split_at_120000(self):
        data = self.big(8)                                         # 384 calls, ~146k hex characters
        self.assertGreater(len(data), kit.MAX_BATCH_HEX)
        parts = kit.split_multisend(data)
        self.assertEqual(len(parts), 2)
        for p in parts:
            self.assertLessEqual(len(p), kit.MAX_BATCH_HEX)
        joined = [x for p in parts for x in kit.multisend_entries(p)]
        self.assertEqual(joined, kit.multisend_entries(data))       # every call once, in order
        data = self.big(30)
        parts = kit.split_multisend(data)
        self.assertGreaterEqual(len(parts), -(-len(data) // kit.MAX_BATCH_HEX))
        self.assertTrue(all(len(p) <= kit.MAX_BATCH_HEX for p in parts))
        self.assertEqual([x for p in parts for x in kit.multisend_entries(p)], kit.multisend_entries(data))

    def test_boundary(self):
        # multiSend hex is 138 + 64k characters; 119,946 is the largest at or under 120,000.
        def one(n):
            return (0, kit.MULTISEND_CALLONLY_141, 0, b"\x01" * n)
        n = (119_946 - 138) // 2 - 85
        self.assertEqual(len(kit.multisend_encode([one(n)])), 119_946)
        self.assertEqual(len(kit.split_multisend(kit.multisend_encode([one(n)]))), 1)
        two = kit.multisend_encode([one(n - 100), one(100)])
        self.assertGreater(len(two), kit.MAX_BATCH_HEX)
        self.assertEqual([len(kit.multisend_entries(p)) for p in kit.split_multisend(two)], [1, 1])
        with self.assertRaises(kit.Refuse):
            kit.split_multisend(kit.multisend_encode([one(n + 32)]))  # one call alone too big

    def test_refuses_what_is_not_a_multisend(self):
        ms, _, _ = fixture_build()
        for bad in ("0x12345678" + ms["data"][10:], ms["data"][:-64], ms["data"][:-2] + "01"):
            with self.assertRaises(kit.Refuse):
                kit.multisend_entries(bad)


class PhaseAChecks(unittest.TestCase):
    def setUp(self):
        self.book = book()
        self.ms, _, self.prop = fixture_build()
        self.e = kit.multisend_entries(self.ms["data"])
        self.keys = {v["symbol"]: H_PUBKEY for v in self.book["vaults"]}
        self.mins = {v["symbol"]: (150, 10 * 10 ** 18) for v in self.book["vaults"]}

    def test_forge_build_is_exactly_the_calls_intended(self):
        kit.verify_batch(self.e, kit.expected_phase_a(self.book, 3, self.keys, self.mins), "phase A")
        kit.verify_proposals(self.prop, self.book, self.book["_safe"], self.e)

    def test_a_different_key_index_minimum_or_pubkey_is_refused(self):
        for idx, keys, mins in ((4, self.keys, self.mins),
                                (3, dict(self.keys, uNVDA="0x" + "00" * 40), self.mins),
                                (3, self.keys, dict(self.mins, uSPY=(200, 10 * 10 ** 18)))):
            with self.assertRaises(kit.Refuse):
                kit.verify_batch(self.e, kit.expected_phase_a(self.book, idx, keys, mins), "phase A")

    def test_a_tampered_proposals_file_is_refused(self):
        p = copy.deepcopy(self.prop)
        p["proposals"][4]["id"] = "0x" + "11" * 32
        with self.assertRaises(kit.Refuse):
            kit.verify_proposals(p, self.book, self.book["_safe"], self.e)
        p = copy.deepcopy(self.prop)
        p["proposals"] = p["proposals"][:-1]
        with self.assertRaises(kit.Refuse):
            kit.verify_proposals(p, self.book, self.book["_safe"], self.e)

    def test_phase_b_is_the_proposals_in_order(self):
        exp = kit.expected_phase_b(self.prop)
        self.assertEqual(len(exp), 18)
        entries = [(0, v, 0, d) for v, d in exp]
        kit.verify_batch(entries, exp, "phase B")
        with self.assertRaises(kit.Refuse):
            kit.verify_batch(entries[1:] + entries[:1], exp, "phase B")


class Signatures(unittest.TestCase):
    def test_sorted_by_owner_address_ascending(self):
        a, b, c = "0x" + "ff" * 20, "0x" + "0A" * 20, "0x" + "5c" * 20
        entries = [(a, sig("aa"), a), (b, sig("bb", 28), b.lower()), (c, sig("cc"), c)]
        sigs, order = kit.order_signatures(entries, [a, b, c], 2)
        self.assertEqual(order, [b.lower(), c, a])
        self.assertEqual(sigs, bytes.fromhex(sig("bb", 28)[2:] + sig("cc")[2:] + sig("aa")[2:]))

    def test_numeric_not_input_order(self):
        o = ["0x" + "%040x" % n for n in (0x9, 0x10, 0xA)]
        _, order = kit.order_signatures([(x, sig("ab"), x) for x in o], o, 3)
        self.assertEqual(order, ["0x" + "%040x" % n for n in (0x9, 0xA, 0x10)])

    def test_v_normalised_and_eth_sign_refused(self):
        self.assertEqual(kit.normalize_sig(sig("ab", 0))[64], 27)
        self.assertEqual(kit.normalize_sig(sig("ab", 1))[64], 28)
        for v in (31, 32, 2):
            with self.assertRaises(kit.Refuse):
                kit.normalize_sig(sig("ab", v))

    def test_refusals(self):
        o = OWNERS
        with self.assertRaises(kit.Refuse):                      # below threshold
            kit.order_signatures([(o[0], sig("aa"), o[0])], o, 2)
        with self.assertRaises(kit.Refuse):                      # a non-owner
            kit.order_signatures([(o[0], sig("aa"), o[0]), ("0x" + "77" * 20, sig("bb"), "0x" + "77" * 20)], o, 2)
        with self.assertRaises(kit.Refuse):                      # does not recover to its claimed owner
            kit.order_signatures([(o[0], sig("aa"), o[1]), (o[1], sig("bb"), o[1])], o, 2)
        with self.assertRaises(kit.Refuse):                      # one owner twice does not make two
            kit.order_signatures([(o[0], sig("aa"), o[0]), (o[0], sig("bb"), o[0])], o, 2)
        sigs, order = kit.order_signatures([(o[1], sig("aa"), o[1]), (o[1], sig("aa"), o[1]), (o[0], sig("bb"), o[0])], o, 2)
        self.assertEqual(len(sigs), 130)

    def test_page_lines_filtered_by_batch_and_nonce(self):
        t = "\n".join(["phaseA-1of2 nonce 5 owner %s signature %s" % (OWNERS[0], sig("aa")),
                       "phaseA-2of2 nonce 6 owner %s signature %s" % (OWNERS[0], sig("bb")),
                       "phaseA-1of2 nonce 6 owner %s signature %s" % (OWNERS[1], sig("cc")),
                       "noise", ""])
        got, others = kit.parse_signatures(t, "phaseA-1of2", 5)
        self.assertEqual(got, [(OWNERS[0], sig("aa"))])
        self.assertEqual(others, 2)

    def test_exec_calldata_ends_with_the_ordered_signatures(self):
        ms, _, _ = fixture_build()
        s, _ = kit.order_signatures([(OWNERS[1], sig("bb"), OWNERS[1]), (OWNERS[0], sig("aa"), OWNERS[0])], OWNERS, 2)
        cd = kit.hb(kit.exec_calldata(kit.MULTISEND_CALLONLY_141, ms["data"], 1, s))
        self.assertEqual(cd[:4].hex(), "6a761202")
        self.assertEqual(kit.dec_bytes_at(cd[4:], 9), s)
        self.assertEqual(kit.dec_bytes_at(cd[4:], 2), kit.hb(ms["data"]))
        self.assertEqual(kit.word(cd[4:], 3), 1)


class Page(unittest.TestCase):
    def test_one_button_per_part_consecutive_nonces_each_under_the_limit(self):
        b = book()
        ms, _, _ = fixture_build()
        big = kit.multisend_encode(kit.multisend_entries(ms["data"]) * 20)
        parts_hex = kit.split_multisend(big)
        self.assertGreaterEqual(len(parts_hex), 3)
        parts = kit.page_parts("phaseA", parts_hex, kit.MULTISEND_CALLONLY_141, 1, 7, kit.labels_of(b))
        for k, p in enumerate(parts):
            p["safeTxHash"] = kit.safe_tx_hash(b["_safe"], p["to"], p["hex"], 1, p["nonce"])
            self.assertLessEqual(p["hexChars"], kit.MAX_BATCH_HEX)
            self.assertEqual(p["label"], "phaseA-%dof%d" % (k + 1, len(parts)))
        self.assertEqual([p["nonce"] for p in parts], list(range(7, 7 + len(parts))))
        html = kit.build_page("Sign </script> test", "intro <b>", b["_safe"], OWNERS, 2, parts)
        payload = json.loads(re.search(r'<script type="application/json" id="batches">(.*?)</script>', html, re.S).group(1))
        self.assertEqual([p["label"] for p in payload["parts"]], [p["label"] for p in parts])
        self.assertEqual([p["nonce"] for p in payload["parts"]], [p["nonce"] for p in parts])
        self.assertEqual(payload["chainId"], 4663)
        self.assertEqual(payload["owners"], OWNERS)
        self.assertEqual(html.count("Sign </script>"), 0)          # escaped, cannot close the script
        for needle in ("eth_signTypedData_v4", "eip6963:requestProvider", "eip6963:announceProvider", "verifyingContract",
                       'primaryType: "SafeTx"', "wallet_switchEthereumChain", "navigator.clipboard", "0xa0e67e2b"):
            self.assertIn(needle, html)
        for p in parts:
            self.assertIn(p["safeTxHash"], html)
        # the copy-box line the page writes is the line exec-safe reads
        line = "%s nonce %d owner %s signature %s" % (parts[1]["label"], parts[1]["nonce"], OWNERS[2], sig("dd"))
        self.assertEqual(kit.parse_signatures(line, parts[1]["label"], parts[1]["nonce"])[0], [(OWNERS[2], sig("dd"))])
        self.assertIn('p.label + " nonce " + p.nonce + " owner " + account + " signature " + sig', html)

    def test_calls_are_described(self):
        b = book()
        ms, _, _ = fixture_build()
        lines = [kit.describe_call(t, cd, kit.labels_of(b)) for _, t, _, cd in kit.multisend_entries(ms["data"])]
        self.assertEqual(lines[0], "certFactory: registerVault(uTSLA vault)")
        self.assertTrue(lines[5].startswith("uTSLA vault: proposeChange(setSettler(settler))"), lines[5])
        self.assertIn("setVenueApiKey(index 3, key %s)" % H_PUBKEY, lines[6])
        self.assertIn("setVenueMinimums(base 150, notional 10.00 USD)", lines[7])


class Book(unittest.TestCase):
    def test_the_real_writer_format_loads(self):
        b = book()
        self.assertEqual([v["symbol"] for v in b["vaults"]], [a[0] for a in kit.ASSETS])

    def test_refusals(self):
        with self.assertRaises(kit.Refuse):                       # governance is not the live Safe
            kit.load_book(BOOK)
        with self.assertRaises(kit.Refuse):                       # stack 4's book
            kit.load_book(os.path.join(os.path.dirname(os.path.dirname(_ethstub.HERE)), "deployments", "4663.json"), sim=True)
        d = jload(BOOK)
        for mutate in (lambda x: x["vaults"].reverse(), lambda x: x["vaults"][0].update(marketIndex=26),
                       lambda x: x["shared"].pop("settler"), lambda x: x.update(chainId=46630)):
            y = copy.deepcopy(d)
            mutate(y)
            with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
                json.dump(y, f)
            try:
                with self.assertRaises(kit.Refuse):
                    kit.load_book(f.name, sim=True)
            finally:
                os.remove(f.name)


class KeeperConfig(unittest.TestCase):
    TEMPLATE = {"rpc": kit.RPC, "api": kit.VENUE_API, "cast": "/opt/keeper/bin/cast", "fill_timeout_sec": 240,
                "auto_recall": True, "market_index": 99, "vault": "0x" + "00" * 20}

    def test_from_the_real_book_format(self):
        b = book()
        cfgs = [kit.keeper_config(b, v, self.TEMPLATE, 1000 + i, 1_800_000_000 + i) for i, v in enumerate(b["vaults"])]
        c = cfgs[0]
        v = b["vaults"][0]
        self.assertEqual((c["vault"], c["oracle"], c["market_index"], c["price_decimals"], c["size_decimals"]),
                         (v["vault"], v["certOracle"], 16, 2, 4))
        self.assertEqual((c["stack"], c["auto_rehedge"], c["settler_key_file"]), (5, False, "/opt/keeper/keys/s5-settler.key"))
        self.assertEqual((c["state_file"], c["api_key_file"]), ("/opt/keeper/state-s5-uTSLA.json", "/opt/keeper/keys/s5-uTSLA-key.json"))
        self.assertEqual((c["rpc"], c["api"], c["cast"], c["fill_timeout_sec"], c["auto_recall"]),
                         (kit.RPC, kit.VENUE_API, "/opt/keeper/bin/cast", 240, True))
        self.assertEqual((c["start_block"], c["funding_start_ts"]), (1000, 1_800_000_000))
        self.assertEqual(len({x["state_file"] for x in cfgs}), 6)
        self.assertEqual(len({x["api_key_file"] for x in cfgs}), 6)

    def test_has_every_key_the_keeper_and_the_relay_require(self):
        c = kit.keeper_config(book(), book()["vaults"][1], self.TEMPLATE, 1, 1)
        src = rd(os.path.join(_ethstub.BIN, "usecert-keeper.py"))
        src = src[src.index("def __init__(self, cfg_path)"):src.index("def _key(self, purpose)")]   # where the config is read
        need = set(re.findall(r'\bc\["(\w+)"\]', src)) - {"attester_pk"}          # attester_pk: stack 4 only
        self.assertTrue(need, "the keeper's required keys were not found")
        self.assertEqual(need - set(c), set())
        rel = rd(os.path.join(_ethstub.BIN, "usecert-funding-relay"))
        need = set(re.findall(r'\bvc\["(\w+)"\]', rel))
        self.assertEqual(need - set(c), set())
        self.assertIn("funding_start_ts", rel)

    def test_template_for_another_exchange_is_refused(self):
        with self.assertRaises(kit.Refuse):
            kit.keeper_config(book(), book()["vaults"][0], dict(self.TEMPLATE, api="https://mainnet.zklighter.elliot.ai"), 1, 1)
        with self.assertRaises(kit.Refuse):
            kit.keeper_config(book(), book()["vaults"][0], dict(self.TEMPLATE, cast=""), 1, 1)

    def test_deploy_block_search(self):
        for dep in (101, 102, 5000, 99_999, 100_000):
            reads = []
            f = lambda b: reads.append(b) or b >= dep                       # noqa: E731
            self.assertEqual(kit.find_deploy_block(f, 100, 100_000), dep)
            self.assertLess(len(reads), 22)
        with self.assertRaises(kit.Refuse):
            kit.find_deploy_block(lambda b: True, 100, 200)
        with self.assertRaises(kit.Refuse):
            kit.find_deploy_block(lambda b: False, 100, 200)


class Attestations(unittest.TestCase):
    O = ["0x" + ("%02x" % (0xa0 + k)) * 20 for k in range(6)]

    def bundle(self, v2=True, oracles=None):
        atts = []
        for k, o in enumerate(oracles or self.O):
            a = {"symbol": "S%d" % k, "certOracle": o, "markSig": "0x" + "11" * 65, "attestSig": "0x" + "22" * 65}
            if v2:
                a.update(markSigVersion=2, markObservedAt=1000, markDeadline=1060)
            atts.append(a)
        return {"generatedAt": 1, "stale": False, "error": None, "refused": [], "attestations": atts}

    def test_good(self):
        self.assertEqual(kit.check_attestations(self.bundle(), self.O, 2), [])
        self.assertEqual(kit.check_attestations(self.bundle(v2=False), self.O, 1), [])   # stack 4, for rollback

    def test_problems(self):
        self.assertTrue(kit.check_attestations(self.bundle(v2=False), self.O, 2))          # v1 marks
        self.assertTrue(kit.check_attestations(self.bundle(oracles=self.O[:5]), self.O, 2))  # one missing
        self.assertTrue(kit.check_attestations(self.bundle(oracles=self.O + ["0x" + "99" * 20]), self.O, 2))
        b = self.bundle()
        b["refused"] = [{"symbol": "S1", "reason": "corporate action window"}]
        self.assertTrue(kit.check_attestations(b, self.O, 2))
        b = self.bundle()
        b["attestations"][0]["markDeadline"] = 1100
        self.assertTrue(kit.check_attestations(b, self.O, 2))
        self.assertTrue(kit.check_attestations(dict(self.bundle(), stale=True), self.O, 2))


class PubkeysEnv(unittest.TestCase):
    def test_round_trip_and_dry_marker(self):
        keys = {"uTSLA": H_PUBKEY, "uSPY": "0x" + "ab" * 40}
        self.assertEqual(kit.parse_pubkeys(kit.pubkeys_env(3, keys)), (3, keys, False))
        self.assertTrue(kit.parse_pubkeys(kit.pubkeys_env(3, keys, dry=True))[2])
        for bad in ("PUBKEY_uTSLA=0x1234\nAPI_KEY_INDEX=3\n", "PUBKEY_uTSLA=%s\n" % H_PUBKEY, "MAINNET_DEPLOYER_PK=0x11\nAPI_KEY_INDEX=3\n"):
            with self.assertRaises(kit.Refuse):
                kit.parse_pubkeys(bad)


class SiteBuildHelpers(unittest.TestCase):
    def test_lf_check_and_deterministic_tar(self):
        d = tempfile.mkdtemp()
        try:
            src = os.path.join(d, "src")
            os.makedirs(os.path.join(src, "src", "chain"))
            wr(os.path.join(src, "src", "chain", "contracts.ts"), b"export const A = 1;\n")
            wr(os.path.join(src, "logo.png"), b"\x89PNG\r\n")
            self.assertEqual(kit.lf_problems(src), [])
            wr(os.path.join(src, "bad.ts"), b"a\r\nb\r\n")
            self.assertEqual(kit.lf_problems(src), ["bad.ts"])
            os.remove(os.path.join(src, "bad.ts"))
            kit.deterministic_tar(src, os.path.join(d, "a.tar"), "")
            kit.deterministic_tar(src, os.path.join(d, "b.tar"), "")
            self.assertEqual(rd(os.path.join(d, "a.tar"), "rb"), rd(os.path.join(d, "b.tar"), "rb"))
            import tarfile
            buf = io.BytesIO()
            with tarfile.open(fileobj=buf, mode="w") as t:
                ti = tarfile.TarInfo("../escape")
                ti.size = 1
                t.addfile(ti, io.BytesIO(b"x"))
            with self.assertRaises(kit.Refuse):
                kit.safe_extract(buf.getvalue(), os.path.join(d, "x"))
        finally:
            shutil.rmtree(d)


def run(argv):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = kit.main(argv)
    return code, out.getvalue()


class OfflineSequence(unittest.TestCase):
    """Every subcommand's --offline dry run, in the order of the runbook, against one simulated chain."""

    def setUp(self):
        self.w = tempfile.mkdtemp(prefix="s5-test-")

    def tearDown(self):
        shutil.rmtree(self.w, ignore_errors=True)

    def m(self, *parts):
        return os.path.join(self.w, *parts)

    def cli(self, *a):
        return run(list(a) + ["--offline", "--workdir", self.w])

    def sigs(self, label, nonce, owners, name):
        p = self.m(name)
        with open(p, "w") as f:
            for k, o in enumerate(owners):
                f.write("%s nonce %d owner %s signature %s\n" % (label, nonce, o, sig("%02x" % (0x31 + k))))
        return p

    def test_monday_to_thursday(self):
        code, out = self.cli("bootstrap", "--book", BOOK)
        self.assertEqual(code, 0, out)
        self.assertIn("would run: sudo -n env BOOK=", out)
        accounts = jload(self.m("opt", "usecert-s5", "accounts.json"))
        self.assertEqual(list(accounts), [a[0] for a in kit.ASSETS])
        code, out = self.cli("bootstrap", "--book", BOOK)            # idempotent
        self.assertEqual(code, 0, out)
        self.assertIn("already bootstrapped; nothing sent", out)

        code, out = self.cli("genkeys", "--accounts", self.m("opt", "usecert-s5", "accounts.json"), "--sim-pubkey", H_PUBKEY)
        self.assertEqual(code, 0, out)
        env = rd(self.m("opt", "keeper", "s5", "pubkeys.env"))
        self.assertTrue(env.startswith(kit.DRY_RUN_MARKER))
        self.assertNotIn("private", env.lower().replace("private halves", ""))
        shutil.copy(self.m("opt", "keeper", "s5", "pubkeys.env"), self.m("opt", "usecert-s5", "pubkeys.env"))

        code, out = self.cli("phase-a", "--book", BOOK, "--from-build", BUILD)
        self.assertEqual(code, 0, out)
        self.assertIn("48 calls, each the one intended", out)
        man = jload(self.m("opt", "usecert-s5", "phaseA", "manifest.json"))
        self.assertEqual([p["label"] for p in man["parts"]], ["phaseA-1of1"])
        self.assertEqual(man["parts"][0]["nonce"], 5)
        self.assertIn(man["parts"][0]["safeTxHash"], out)
        for f in ("index.html", "phaseA-1of1.hex", "phaseA.txbuilder.json", "phaseA.multisend.json", "phaseA-proposals.json"):
            self.assertTrue(os.path.exists(self.m("opt", "usecert-s5", "phaseA", f)), f)
        code, out = self.cli("phase-a", "--book", BOOK, "--from-build", BUILD)       # idempotent
        self.assertEqual(code, 0, out)
        self.assertIn("already this batch", out)

        batch = self.m("opt", "usecert-s5", "phaseA", "phaseA-1of1.hex")
        one = self.sigs("phaseA-1of1", 5, OWNERS[:1], "a1.txt")
        code, out = self.cli("exec-safe", "--book", BOOK, "--batch", batch, "--nonce", "5", "--sigs", one)
        self.assertEqual(code, 2, out)
        self.assertIn("the Safe needs 2", out)
        two = self.sigs("phaseA-1of1", 5, [OWNERS[2], OWNERS[0]], "a2.txt")
        code, out = self.cli("exec-safe", "--book", BOOK, "--batch", batch, "--nonce", "6", "--sigs", two)
        self.assertEqual(code, 2, out)                                             # the nonce it was not signed for
        code, out = self.cli("exec-safe", "--book", BOOK, "--batch", batch, "--nonce", "5", "--sigs", two)
        self.assertEqual(code, 0, out)
        self.assertIn("in ascending address order: %s, %s" % (kit.checksum(OWNERS[0]), kit.checksum(OWNERS[2])), out)
        self.assertIn("every read-back holds on the simulated chain (54 checks)", out)
        code, out = self.cli("exec-safe", "--book", BOOK, "--batch", batch, "--nonce", "5", "--sigs", two)
        self.assertEqual(code, 0, out)
        self.assertIn("already executed; nothing sent", out)

        code, out = self.cli("phase-b", "--book", BOOK)
        self.assertEqual(code, 2, out)
        self.assertIn('SafeBatches_PhaseBTooEarly("uTSLA", "setSettler"', out)
        code, out = self.cli("keeper-configs", "--book", BOOK)
        self.assertEqual(code, 0, out)
        cfg = jload(self.m("opt", "keeper", "vaults", "s5-uTSLA.json"))
        self.assertEqual((cfg["stack"], cfg["auto_rehedge"]), (5, False))
        self.assertTrue(os.path.exists(self.m("etc", "systemd", "system", "usecert-keeper@s5-uMSFT.service.d", "60-stack5-code.conf")))
        code, out = self.cli("keeper-configs", "--book", BOOK, "--start")
        self.assertEqual(code, 2, out)                                             # phase B not on chain yet
        self.assertIn("phase B not executed", out)

        code, out = self.cli("phase-b", "--book", BOOK, "--sim-advance", "172800")
        self.assertEqual(code, 0, out)
        self.assertIn("18 applies, byte for byte", out)
        b2 = self.sigs("phaseB-1of1", 6, [OWNERS[1], OWNERS[0]], "b.txt")
        code, out = self.cli("exec-safe", "--book", BOOK, "--batch", self.m("opt", "usecert-s5", "phaseB", "phaseB-1of1.hex"),
                             "--nonce", "6", "--sigs", b2)
        self.assertEqual(code, 0, out)
        self.assertIn("venueMinBase(): 150", out)

        code, out = self.cli("keeper-configs", "--book", BOOK, "--start")
        self.assertEqual(code, 0, out)
        self.assertIn("would run: systemctl start usecert-keeper@s5-uTSLA", out)
        code, out = self.cli("funding-relay", "--book", BOOK)
        self.assertEqual(code, 0, out)
        self.assertIn("FUNDING_RELAY_VAULTS=/opt/keeper/vaults/s5-*.json", out)

        code, out = self.cli("open", "--book", BOOK, "--vaults", "uTSLA", "--cap18", "1000000000000000000000")
        self.assertEqual(code, 0, out)
        o = self.sigs("open-uTSLA-1of1", 7, OWNERS[:2], "o.txt")
        code, out = self.cli("exec-safe", "--book", BOOK, "--batch", self.m("opt", "usecert-s5", "open-uTSLA", "open-uTSLA-1of1.hex"),
                             "--nonce", "7", "--sigs", o)
        self.assertEqual(code, 0, out)
        self.assertIn("absoluteCap18(uTSLA vault): 1000000000000000000000", out)

        b4 = jload(os.path.join(os.path.dirname(os.path.dirname(_ethstub.HERE)), "deployments", "4663.json"))
        b4["senders"]["attester"] = jload(BOOK)["senders"]["attester"]
        os.makedirs(self.m("opt", "keeper"), exist_ok=True)
        wr(self.m("opt", "keeper", "book-stack4.json"), json.dumps(b4).encode())
        code, out = self.cli("signer-cutover")
        self.assertEqual(code, 0, out)
        self.assertNotIn("50-stack5.conf  ->", out)                               # no switch without --switch
        code, out = self.cli("signer-cutover", "--switch")
        self.assertEqual(code, 0, out)
        self.assertTrue(os.path.exists(self.m("etc", "systemd", "system", "usecert-signer-mainnet.service.d", "50-stack5.conf")))
        code, out = self.cli("signer-cutover", "--rollback")
        self.assertEqual(code, 0, out)
        self.assertIn("would remove", out)


class Hosts(unittest.TestCase):
    def test_every_subcommand_refuses_the_wrong_host_and_has_a_dry_run(self):
        ap = kit.parser()
        for name, host in kit.HOSTS.items():
            extra = {"open": ["--vaults", "uTSLA"], "exec-safe": ["--batch", "x", "--nonce", "1", "--sigs", "y"]}.get(name, [])
            a = ap.parse_args([name, "--dry-run"] + extra)
            self.assertTrue(a.dry_run)
            if host != kit.detect_host():
                code, out = run([name] + extra)
                self.assertEqual(code, 2, out)
                self.assertIn("runs on the %s host" % host, out)

    def test_systemd_files_the_kit_installs_exist(self):
        for f in ("usecert-keeper@.service.d-50-stack5-settler.conf", "usecert-keeper@.service.d-60-stack5-code.conf",
                  "usecert-signer-mainnet.service.d-50-stack5.conf", "usecert-funding-relay.service.d-50-stack5.conf",
                  "usecert-funding-relay.service", "usecert-funding-relay.timer"):
            self.assertTrue(os.path.exists(os.path.join(kit.SYSTEMD_SRC, f)), f)
        s = rd(os.path.join(kit.SYSTEMD_SRC, "usecert-signer-mainnet.service.d-50-stack5.conf"))
        for k in ("STACK=5", "MARK_SIG_VERSION=2", "OI_SOURCE=venue", "SANITY_CHECKS=1", "MULTIPLIER_CHECKS=1",
                  "ExecStart=\n", kit.F_SIGNER_S5, kit.F_BOOK5):
            self.assertIn(k, s)
        s = rd(os.path.join(kit.SYSTEMD_SRC, "usecert-keeper@.service.d-60-stack5-code.conf"))
        self.assertIn("ExecStart=\n", s)
        self.assertIn(kit.F_KEEPER_S5, s)


if __name__ == "__main__":
    unittest.main()
