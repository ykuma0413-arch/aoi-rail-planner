"""
Cosmos DB Exponential Backoff リトライのユニットテスト
実行: python test_cosmos_retry.py
"""
import asyncio
import sys, os
sys.path.insert(0, os.path.dirname(__file__))

from layout_generator.cosmos_client import _with_exponential_backoff


class FakeCosmos429(Exception):
    status_code = 429
    retry_after_ms = None


class FakeCosmos503(Exception):
    status_code = 503
    retry_after_ms = None


class FakeCosmosOK:
    pass


async def test_retry_on_429():
    call_count = 0

    async def flaky_op():
        nonlocal call_count
        call_count += 1
        if call_count < 3:
            raise FakeCosmos429()
        return "success"

    result = await _with_exponential_backoff(flaky_op)
    assert result == "success", f"Expected 'success', got {result}"
    assert call_count == 3, f"Expected 3 calls, got {call_count}"
    print(f"✅ test_retry_on_429 passed (retried {call_count-1} times)")


async def test_max_retries_exceeded():
    call_count = 0

    async def always_fail():
        nonlocal call_count
        call_count += 1
        raise FakeCosmos429()

    try:
        await _with_exponential_backoff(always_fail)
        assert False, "Should have raised"
    except FakeCosmos429:
        pass
    # 6回呼ばれるはず（初回 + 5リトライ）
    assert call_count == 6, f"Expected 6 calls, got {call_count}"
    print(f"✅ test_max_retries_exceeded passed (called {call_count} times)")


async def test_no_retry_on_400():
    call_count = 0

    class Fake400(Exception):
        status_code = 400

    async def bad_request():
        nonlocal call_count
        call_count += 1
        raise Fake400()

    try:
        await _with_exponential_backoff(bad_request)
        assert False, "Should have raised"
    except Fake400:
        pass
    assert call_count == 1, f"Expected 1 call (no retry), got {call_count}"
    print(f"✅ test_no_retry_on_400 passed (no retry on 400)")


async def test_success_first_try():
    async def ok():
        return 42

    result = await _with_exponential_backoff(ok)
    assert result == 42
    print("✅ test_success_first_try passed")


async def main():
    print("Cosmos DB Exponential Backoff テスト")
    print("="*40)
    await test_success_first_try()
    await test_no_retry_on_400()
    await test_retry_on_429()
    await test_max_retries_exceeded()
    print("\n🎉 全テスト合格")


if __name__ == "__main__":
    asyncio.run(main())
