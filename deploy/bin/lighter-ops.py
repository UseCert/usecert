"""Small CLI over Lighter's official SDK, for the keeper and for proving it.

The SDK's SignerClient opens an aiohttp connector in its constructor, so it must be built
inside a running event loop - constructing it at module level raises "no running event loop".

  lighter_ops.py genkey KEYFILE ACCOUNT_INDEX API_KEY_INDEX
  lighter_ops.py check  KEYFILE API
  lighter_ops.py market KEYFILE API MARKET BASE PRICE_TICK IS_ASK

genkey writes the private key to KEYFILE (mode 600) and prints ONLY the public key. Run it on
the keeper server so the private half never leaves it; governance registers the public half.
"""
import asyncio
import json
import sys
import time

import lighter


def load(path):
    with open(path) as f:
        return json.load(f)


async def client(k, api):
    return lighter.SignerClient(
        url=api,
        account_index=k["account_index"],
        api_private_keys={k["api_key_index"]: k["private"]},
    )


async def check(k, api):
    c = await client(k, api)
    try:
        err = c.check_client()
        print("OK" if err is None else "ERR " + str(err)[:160])
    finally:
        await c.close()


async def market(k, api, mkt, base, price, is_ask):
    c = await client(k, api)
    try:
        tx, resp, err = await c.create_market_order(
            market_index=mkt,
            client_order_index=int(time.time() * 1000) % (2 ** 40),
            base_amount=base,
            avg_execution_price=price,
            is_ask=bool(is_ask),
        )
        if err is not None:
            print("ERR " + str(err)[:300])
            sys.exit(1)
        print("SENT " + str(resp)[:300])
    finally:
        await c.close()


def genkey(path, account_index, api_key_index):
    import os
    from lighter.signer_client import create_api_key
    priv, pub, err = create_api_key()
    if err:
        print("ERR " + str(err)); sys.exit(1)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)   # never overwrite a key
    with os.fdopen(fd, "w") as f:
        json.dump({"account_index": account_index, "api_key_index": api_key_index,
                   "private": priv, "public": pub}, f)
    print(pub)


def main():
    if sys.argv[1] == "genkey":
        genkey(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
        return
    cmd, keyfile, api = sys.argv[1], sys.argv[2], sys.argv[3]
    k = load(keyfile)
    if cmd == "check":
        asyncio.run(check(k, api))
    elif cmd == "market":
        mkt, base, price, is_ask = (int(x) for x in sys.argv[4:8])
        asyncio.run(market(k, api, mkt, base, price, is_ask))
    else:
        print("unknown command " + cmd)
        sys.exit(2)


if __name__ == "__main__":
    main()
