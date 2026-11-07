# Dagda

Dagda is a batteries-included backend framework being built in Odin. Its intended scope brings application conventions, PostgreSQL, authentication, background jobs, and development tooling into one workflow for building JSON APIs.

**Status:** M0 runtime prototype validated for its bounded local workload: integration/failure tests and a 30-minute stability run pass. Initial M1 application lifecycle, configuration, routing, middleware, request IDs, and access logs are implemented with an example API and passing integration checks. Typed JSON request/response support passes unit and network integration checks, including bounded uploads and shutdown. Field validation and structured 422 errors also pass Odin unit and HTTP integration checks. The framework CLI, authentication, migrations, and jobs remain specifications. This prototype is not production-ready.

Read the [project specification](SPEC.md) for scope, runtime design, release milestones, and acceptance criteria.

For the runtime proof, see [M0 setup, architecture, and checks](docs/M0.md).
The first application packages and example are described in [M1 lifecycle, configuration, routing, and middleware](docs/M1.md). See [typed JSON](docs/JSON.md) for request/response APIs and limits, and [field validation](docs/VALIDATION.md) for rules and structured errors.

```sh
bash scripts/setup-odin.sh
./scripts/build.sh
./scripts/test-unit.sh
./scripts/test.sh
./scripts/load-test.sh # 30-second warmup + 30-minute stability measurement
```

Currently requires Linux x86_64 with permitted `io_uring`, a C compiler, libpq 17+, Python 3, and PostgreSQL server tools for integration tests. Tests create and remove their own temporary database.

## Product direction

- Odin application code and native deployment artifacts.
- PostgreSQL for application data, sessions, and durable jobs.
- Typed request and response structures, explicit SQL, and generated resource code.
- A `dagda` CLI for creating, developing, testing, and building applications.
- Linux production deployments behind a reverse proxy, with macOS development support targeted after the initial runtime proof.

The framework owns the routine work around an API application. Application developers own their business logic, authorization policies, and schema changes.

## Intended workflow

These commands describe the target developer experience:

```sh
dagda new billing
cd billing
dagda doctor
dagda db setup
dagda generate resource invoice title:string total_cents:i64
dagda db migrate
dagda dev
dagda test
dagda build --release
```

Production uses the compiled application:

```sh
./billing migrate
./billing serve
./billing worker
```

The application connects to PostgreSQL and may depend on packaged native libraries. Deployment does not require the Odin compiler or the development CLI.

## First milestone

Prove an Odin HTTP request can execute a PostgreSQL query on a bounded worker pool and return a JSON response without blocking the HTTP event loop or violating memory ownership. Exercise overload, client disconnection, query failure, and shutdown before expanding the framework.

## Name

The working public description is **Dagda Web**, and the proposed command is `dagda`. Package and procedure names use ordinary terms such as `db`, `jobs`, `auth`, and `routes`.

Dagda draws its name from Irish mythology. The [National Museum of Ireland](https://source.museum.ie/en-IE/Collections-Research/Irish-Antiquities-Division-Collections/Irish-Antiquities-Articles/The-Winter-solstice-at-Newgrange) identifies An Dagda as a chief god of the Tuatha Dé Danann and translates the name as “Good God.” The comparison with Odin is an analogy, not a direct equivalence between the traditions.

An unrelated [container-security project already uses Dagda](https://github.com/eliasgranderubio/dagda). Use the backend-framework description consistently; domain and package namespace availability remain to be checked before distribution.
