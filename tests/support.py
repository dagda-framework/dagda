"""Owned, disposable services shared by runtime checks. Never uses an existing DB."""
import datetime
import http.client
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]


def wait_until(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if predicate():
                return
        except (OSError, http.client.HTTPException):
            pass
        time.sleep(0.025)
    raise AssertionError('Condition did not become true before timeout')


def process_sample(pid):
    """Linux process resources; RSS includes native libraries and HTTP arenas."""
    root = Path('/proc') / str(pid)
    values = {}
    for line in (root / 'status').read_text().splitlines():
        key, _, value = line.partition(':')
        if key in ('VmRSS', 'VmSize', 'Threads'):
            values[key] = int(value.split()[0])
    return {'rss_kib': values['VmRSS'], 'virtual_kib': values['VmSize'],
            'threads': values['Threads'], 'fds': len(list((root / 'fd').iterdir()))}


class RuntimeFixture:
    def __init__(self, artifacts=None, binary=None):
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
        self.artifacts = Path(artifacts or ROOT / 'build/runtime-checks' / stamp).resolve()
        self.binary = Path(binary or ROOT / 'build/dagda-m0').resolve()
        self.process = None
        self.output = None
        self.temporary = None
        self.initialized = False

    def __enter__(self):
        self.artifacts.mkdir(parents=True, exist_ok=False)
        print(f'Artifacts: {self.artifacts}', flush=True)
        for command in ('initdb', 'pg_ctl', 'psql'):
            if not shutil.which(command):
                raise RuntimeError(f'Missing test dependency: {command}')
        self.temporary = Path(tempfile.mkdtemp(prefix='dagda-m0-'))
        self.directory = self.temporary
        self.database = self.directory / 'postgres'
        self.pg_log = self.artifacts / 'postgres.log'
        self.server_log = self.artifacts / 'server.log'
        # Ignore inherited PG* settings, including credentials and service files.
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
        self.conninfo = f'host={self.directory} port=55439 dbname=postgres application_name=dagda-m0'
        try:
            with (self.artifacts / 'initdb.log').open('w') as log:
                subprocess.run(['initdb', '-D', str(self.database), '-A', 'trust', '--no-locale', '-E', 'UTF8'],
                               check=True, stdout=log, stderr=subprocess.STDOUT, env=self.env, timeout=30)
            self.initialized = True
            self.start_database()
            subprocess.run(['psql', self.conninfo, '-X', '-v', 'ON_ERROR_STOP=1', '-f', str(ROOT / 'tests/seed.sql')],
                           check=True, stdout=subprocess.DEVNULL, env=self.env, timeout=10)
            with socket.socket() as reservation:
                reservation.bind(('127.0.0.1', 0))
                self.port = reservation.getsockname()[1]
            env = dict(self.env, DAGDA_DATABASE_URL=self.conninfo,
                       DAGDA_LISTEN=f'127.0.0.1:{self.port}', DAGDA_TEST_ROUTES='1', DAGDA_DEADLINE_MS='1200')
            self.output = self.server_log.open('w')
            self.process = subprocess.Popen([str(self.binary)], env=env, stdout=self.output, stderr=self.output)
            def ready():
                self.assert_alive()
                return self.request('/health/live')[0] == 200
            wait_until(ready)
            return self
        except BaseException:
            self.__exit__(*__import__('sys').exc_info())
            raise

    def start_database(self):
        subprocess.run(['pg_ctl', '-D', str(self.database), '-l', str(self.pg_log), '-o',
                        f"-k {self.directory} -h '' -p 55439 -F", '-w', '-t', '10', 'start'],
                       check=True, stdout=subprocess.DEVNULL, env=self.env, timeout=15)

    def stop_database(self):
        subprocess.run(['pg_ctl', '-D', str(self.database), '-m', 'immediate', '-w', '-t', '10', 'stop'],
                       check=True, stdout=subprocess.DEVNULL, env=self.env, timeout=15)

    def sql(self, query):
        conninfo = self.conninfo.replace('application_name=dagda-m0', 'application_name=test-monitor')
        result = subprocess.run(['psql', conninfo, '-X', '-v', 'ON_ERROR_STOP=1', '-Atc', query],
                                check=True, capture_output=True, text=True, env=self.env, timeout=10)
        return result.stdout.strip()

    def request(self, path, method='GET'):
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        try:
            connection.request(method, path)
            response = connection.getresponse()
            payload = response.read()
            headers = dict(response.getheaders())
            try:
                body = json.loads(payload)
            except json.JSONDecodeError as error:
                raise AssertionError(f'{path}: status={response.status}, headers={headers!r}, body={payload!r}') from error
            return response.status, body, headers
        finally:
            connection.close()

    def inflight(self):
        return self.request('/_test/state')[1]['inflight']

    def connect(self):
        return socket.create_connection(('127.0.0.1', self.port), timeout=4)

    def assert_alive(self):
        if self.process.poll() is not None:
            raise AssertionError(f'Runtime exited with {self.process.returncode}; see {self.server_log}')

    def __exit__(self, kind, value, traceback):
        # Repeated Ctrl-C must not interrupt pg_ctl and then delete a live data
        # directory. Cleanup is bounded, and restores the caller's handler.
        previous_interrupt = None
        if threading.current_thread() is threading.main_thread():
            previous_interrupt = signal.signal(signal.SIGINT, signal.SIG_IGN)
        database_stopped = not self.initialized
        try:
            if self.process is not None and self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=6)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=5)
            if self.output:
                self.output.close()
            if self.initialized:
                running = subprocess.run(['pg_ctl', '-D', str(self.database), 'status'],
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                         env=self.env, timeout=5)
                if running.returncode == 0:
                    self.stop_database()
                    database_stopped = True
                elif running.returncode == 3:
                    database_stopped = True
                else:
                    raise RuntimeError(f'Cannot establish database state; preserved {self.database}')
        finally:
            try:
                if kind is not None:
                    for path in (self.pg_log, self.server_log):
                        if path.exists():
                            print(f'--- {path.name} (tail) ---\n{path.read_text()[-6000:]}', flush=True)
                if self.temporary and database_stopped:
                    shutil.rmtree(self.temporary)
                elif self.temporary:
                    print(f'Database shutdown not confirmed; preserved {self.temporary}', flush=True)
            finally:
                if previous_interrupt is not None:
                    signal.signal(signal.SIGINT, previous_interrupt)
