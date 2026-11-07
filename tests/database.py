"""Own PostgreSQL/socket lifecycle; database semantics are tested in Odin."""
import concurrent.futures
import json
import subprocess
import time
from support import ROOT, RuntimeFixture, wait_until


def main():
    with RuntimeFixture(binary=ROOT / 'build/dagda-api', environment={'DAGDA_ENV': 'test'}) as fixture:
        result = subprocess.run([str(ROOT / 'scripts/odin.sh'), 'test', 'tests/database',
                                 '-out:build/database-tests', '-debug'], cwd=ROOT,
                                env=dict(fixture.env, DAGDA_DATABASE_URL=fixture.conninfo),
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
        (fixture.artifacts / 'odin-tests.log').write_text(result.stdout)
        print(result.stdout, flush=True)
        assert result.returncode == 0, 'Database Odin tests failed'
        assert '[WARN' not in result.stdout, 'Odin memory tracking reported a problem'
        def transfer(amount, delay=0):
            return fixture.request('/_test/transfer', method='POST',
                headers={'Content-Type': 'application/json'},
                body=json.dumps({'amount': amount, 'delay_ms': delay}))
        assert transfer(25)[0] == 200
        assert fixture.sql('SELECT balance FROM dagda_m2_accounts ORDER BY id') == '975\n25'
        status, body, headers = transfer(999999)
        assert status == 409 and body['error']['code'] == 'balance_constraint', (status, body)
        assert body['request_id'] == headers['x-request-id']
        assert fixture.sql('SELECT balance FROM dagda_m2_accounts ORDER BY id') == '975\n25'
        assert fixture.request('/_test/abandon', method='POST')[0] == 500
        assert fixture.sql('SELECT balance FROM dagda_m2_accounts ORDER BY id') == '975\n25'
        # Saturate both workers inside multi-query transactions, then check the loop.
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            pending = [executor.submit(transfer, 1, 600) for _ in range(2)]
            wait_until(lambda: fixture.sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='dagda-m0' AND wait_event='PgSleep'") == '2')
            before = time.monotonic()
            assert fixture.request('/health/live')[0] == 200
            assert time.monotonic() - before < .4
            assert all(future.result()[0] == 200 for future in pending)
        assert transfer(1, 2000)[0] == 503
        for _ in range(20):
            assert transfer(1)[0] == 200
        assert fixture.sql('SELECT sum(balance) FROM dagda_m2_accounts') == '1000'
        print('PASS worker transactions commit/rollback, liveness, cancellation and connection recovery', flush=True)
        (fixture.artifacts / 'result.json').write_text(json.dumps({
            'passed': True, 'suite': 'M2 database API', 'odin_integration_tests': 4,
            'worker_checks': ['commit', 'constraint rollback', 'abandoned transaction cleanup', 'request IDs', 'event-loop liveness',
                              'deadline cancellation', 'connection reuse', 'balance conservation']}, indent=2)+'\n')


if __name__ == '__main__':
    main()
