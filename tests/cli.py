"""Exercise the copied CLI and a generated app with an owned PostgreSQL service."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from support import ROOT, RuntimeFixture


def main():
    pin = json.loads((ROOT / 'dagda.lock').read_text())['odin']
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('DAGDA_', 'PG'))}
    env['DAGDA_ODIN'] = str(ROOT / '.tools' / f"odin-{pin['version']}" / 'odin')
    with tempfile.TemporaryDirectory(prefix='dagda-cli-integration-') as directory:
        parent = Path(directory) / 'space $ parent'
        parent.mkdir()
        cli = parent / 'dagda'
        shutil.copy2(ROOT / 'build/dagda', cli)
        project = parent / 'billing'
        records = []

        def command(*args, cwd=project, environment=env, success=True):
            result = subprocess.run([str(cli), *args], cwd=cwd, env=environment,
                                    text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=120)
            records.append({'command': list(args), 'exit_code': result.returncode,
                            'output': result.stdout})
            assert (result.returncode == 0) == success, records[-1]
            return result.stdout

        command('new', 'billing', '--dry-run', cwd=parent)
        assert not project.exists()
        command('new', 'billing', cwd=parent)
        command('new', 'billing', cwd=parent, success=False)
        command('doctor')
        command('doctor', '--database', success=False)
        command('build', environment=dict(env, DAGDA_ODIN='/bin/true'), success=False)
        command('test')
        command('build', '--release')
        metadata = json.loads((project / 'build/build-info.json').read_text())
        assert metadata['mode'] == 'release'
        assert metadata['compiler'] == pin['compiler_version']
        secret = 'cli-secret-must-not-appear'
        output = command('doctor', environment=dict(env, DAGDA_DATABASE_URL=f'password={secret}',
                                                     DAGDA_WORKERS='not-a-number'), success=False)
        assert secret not in output
        print('PASS standalone CLI generation, pins, request tests, release build and configuration diagnostics', flush=True)

        with RuntimeFixture(binary=project / 'build/billing') as fixture:
            try:
                command('doctor', '--database', environment=dict(env, DAGDA_DATABASE_URL=fixture.conninfo))
                status, body, _ = fixture.request('/')
                assert status == 200 and body == {'name': 'billing', 'status': 'ok'}
                assert fixture.request('/health/ready')[0] == 200
                status, body, _ = fixture.request('/echo', method='POST',
                    headers={'Content-Type': 'application/json'}, body='{"message":"hello"}')
                assert status == 200 and body == {'message': 'hello'}
                status, body, headers = fixture.request('/echo', method='POST',
                    headers={'Content-Type': 'application/json'}, body='{"message":""}')
                assert status == 422 and body['error']['code'] == 'validation_failed'
                assert body['request_id'] == headers['x-request-id']
                assert fixture.request('/missing')[0] == 404
                fixture.assert_alive()
                print('PASS generated app boots; database doctor, readiness, typed JSON and validation work over HTTP', flush=True)
            finally:
                (fixture.artifacts / 'cli.json').write_text(json.dumps(records, indent=2) + '\n')
        assert fixture.process.returncode == 0, fixture.process.returncode
        result = {'passed': True, 'suite': 'M1 generated application and CLI',
                  'build': metadata,
                  'cli_sha256': hashlib.sha256(cli.read_bytes()).hexdigest(),
                  'application_sha256': hashlib.sha256((project / 'build/billing').read_bytes()).hexdigest(),
                  'shutdown_exit_code': fixture.process.returncode}
        (fixture.artifacts / 'result.json').write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
